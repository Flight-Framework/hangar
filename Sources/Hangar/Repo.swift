import Logging
import Metrics
import PostgresNIO

/// Execution against PostgresNIO. `Repo` takes a connection
/// source and nothing else — it has no idea what a request, a job, or a
/// scope is; that's the caller's business, which is what keeps Hangar
/// Flight-independent.
public struct Repo: Sendable {
    /// Where statements run: the pooled client(s), or — inside
    /// `transaction { }` — the one connection the transaction owns, with
    /// its nesting depth (0 = outermost `BEGIN`, ≥1 = savepoints).
    enum Backend: Sendable {
        /// `replica` non-nil means reads route there; writes and
        /// transactions always use `primary`.
        case client(primary: PostgresClient, replica: PostgresClient?)
        case transaction(PostgresConnection, depth: Int)
    }

    /// Whether a statement reads or writes — what read-replica routing
    /// keys on. Everything inside a `transaction { }` ignores this and
    /// uses the transaction's connection: a read inside a transaction must
    /// see that transaction's uncommitted writes.
    enum Intent: String, Sendable {
        case read
        case write
    }

    let backend: Backend
    /// Passed through to PostgresNIO per query, and the sink for Hangar's
    /// own per-query debug line; `nil` disables both.
    let logger: Logger?

    public init(client: PostgresClient, logger: Logger? = nil) {
        self.backend = .client(primary: client, replica: nil)
        self.logger = logger
    }

    /// Read-replica routing: `all`/`one`/`count`/`exists`/`stream`
    /// go to `replica`; writes and everything inside a `transaction` block
    /// go to `primary`. The single-client initializer keeps both pointing
    /// at the same place.
    public init(primary: PostgresClient, replica: PostgresClient, logger: Logger? = nil) {
        self.backend = .client(primary: primary, replica: replica)
        self.logger = logger
    }

    init(transaction connection: PostgresConnection, depth: Int, logger: Logger?) {
        self.backend = .transaction(connection, depth: depth)
        self.logger = logger
    }

    /// A repo pinned to one specific connection — for integration layers
    /// that manage connection lifetime themselves (e.g. Flight's
    /// request-scoped connections, the design). Every statement runs on
    /// this connection; `transaction { }` issues `BEGIN`/`COMMIT` on it
    /// (nesting becomes savepoints as usual), and there is no replica
    /// routing — the connection *is* the destination.
    ///
    /// The caller owns checkout and return; the repo must not outlive the
    /// connection's lease.
    /// - Parameters:
    ///   - connection: The connection every statement runs on.
    ///   - logger: Where statements are logged at debug level. `nil` stays
    ///     quiet.
    ///   - inTransaction: Whether `connection` is **already** inside a
    ///     transaction the caller opened.
    ///
    ///     This matters more than it looks. At `false` — the default — the repo
    ///     believes it is outermost, so `transaction { }` emits a literal
    ///     `BEGIN`/`COMMIT`. If the connection was already inside someone
    ///     else's transaction, Postgres warns and ignores the redundant
    ///     `BEGIN`, and the `COMMIT` then **ends the caller's transaction** —
    ///     so work the caller intended to roll back becomes durable.
    ///
    ///     Pass `true` when handing a connection to this repo from inside an
    ///     open transaction, as a framework integration binding a
    ///     request-scoped connection does. `transaction { }` then nests as a
    ///     savepoint, which is what it should have been.
    public init(
        connection: PostgresConnection,
        inTransaction: Bool = false,
        logger: Logger? = nil
    ) {
        self.backend = .transaction(connection, depth: inTransaction ? 1 : 0)
        self.logger = logger
    }

    /// True when this repo is operating inside an open transaction.
    ///
    /// That covers the repo handed to a `transaction { }` body, and a
    /// connection-bound repo constructed with `inTransaction: true`. One at
    /// the default `inTransaction: false` reports false until its own
    /// `transaction { }` opens one.
    public var isInTransaction: Bool {
        if case .transaction(_, let depth) = backend { return depth > 0 }
        return false
    }

    // MARK: Reads

    /// Full-model fetch: decodes rows, then runs the query's preloads
    /// — one batched query per association, grouped and assigned
    /// into each model's `Loadable`.
    public func all<M: Table>(_ query: Query<M, M>) async throws -> [M] {
        var models: [M] = try await rows(for: SQLRenderer.select(query), intent: .read, operation: "select")
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models
    }

    /// Projected fetch: `Result` was changed by `.select {}`, and the
    /// selection installed the row decoder for it.
    public func all<M, R>(_ query: Query<M, R>) async throws -> [R] {
        let selection = try validatedSelection(of: query)
        let sequence = try await execute(SQLRenderer.select(query).postgresQuery(), intent: .read, operation: "select")
        var results: [R] = []
        for try await row in sequence {
            results.append(try selection.decode(row))
        }
        return results
    }

    /// At most one row, or `nil`. More than one match is an error, not a
    /// silent first-row pick. Preloads apply to the returned model.
    public func one<M: Table>(_ query: Query<M, M>) async throws -> M? {
        var models: [M] = try await rows(for: SQLRenderer.select(query.limit(2)), intent: .read, operation: "select")
        guard models.count <= 1 else {
            throw HangarError.tooManyRows(table: M.schema.name)
        }
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models.first
    }

    public func one<M, R>(_ query: Query<M, R>) async throws -> R? {
        let results: [R] = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: M.schema.name)
        }
        return results.first
    }

    // MARK: Streaming
    //
    // `all` materializes every row; over a large result set that is the
    // memory footprint of the whole table. `stream` decodes lazily off
    // PostgresNIO's row sequence instead, so a million-row export costs one
    // row at a time.
    //
    // Two deliberate limits, both consequences of laziness rather than
    // oversights: preloads do not run (they need the full parent set to
    // batch, which is exactly what streaming refuses to hold), and the
    // sequence must be consumed inside the call — the connection is leased
    // for the duration.

    /// Streams full models, decoding one row at a time. Preloads on the
    /// query are **not** applied — batching needs every parent at once; use
    /// `all` when you need associations.
    public func stream<M: Table, T>(
        _ query: Query<M, M>,
        _ body: (PostgresRowStream<M>) async throws -> T
    ) async throws -> T {
        let rows = try await execute(SQLRenderer.select(query).postgresQuery(), intent: .read, operation: "select")
        return try await body(PostgresRowStream(rows: rows) { try M(from: $0) })
    }

    /// Streams a projection, decoding one row at a time.
    public func stream<M, R, T>(
        _ query: Query<M, R>,
        _ body: (PostgresRowStream<R>) async throws -> T
    ) async throws -> T {
        let selection = try validatedSelection(of: query)
        let rows = try await execute(SQLRenderer.select(query).postgresQuery(), intent: .read, operation: "select")
        return try await body(PostgresRowStream(rows: rows, decode: selection.decode))
    }

    private func validatedSelection<M, R>(of query: Query<M, R>) throws -> Selection<R> {
        guard let selection = query.selection else {
            throw HangarError.invalidProjection(
                table: M.schema.name,
                reason: "the query's Result is not \(M.self) but no .select {} installed a projection — this is a Hangar bug.")
        }
        if let invalid = selection.invalid {
            throw invalid
        }
        return selection
    }

    /// How many rows match the query's conditions. Ordering, limit, and
    /// offset are ignored.
    public func count<M, R>(_ query: Query<M, R>) async throws -> Int {
        try await scalar(Int.self, for: SQLRenderer.count(query), table: M.schema.name, operation: "count")
    }

    public func exists<M, R>(_ query: Query<M, R>) async throws -> Bool {
        try await scalar(Bool.self, for: SQLRenderer.exists(query), table: M.schema.name, operation: "exists")
    }

    // MARK: Writes — always explicit; no dirty tracking, no autoflush

    /// Inserts the model and returns it as the database now holds it —
    /// database-generated columns (`@ID(generated: true)`, defaults) are
    /// read back via RETURNING.
    @discardableResult
    public func insert<M: Table>(_ model: M) async throws -> M {
        let returned: [M] = try await rows(for: SQLRenderer.insert(model), intent: .write, operation: "insert")
        guard let stored = returned.first else {
            // INSERT... RETURNING yields exactly one row; none means a rule
            // or trigger swallowed the write.
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    /// Writes every non-key column of the model's row, identified by primary
    /// key, and returns the stored result. Throws `HangarError.staleModel`
    /// if the row no longer exists.
    @discardableResult
    public func update<M: Table>(_ model: M) async throws -> M {
        let returned: [M] = try await rows(for: SQLRenderer.update(model), intent: .write, operation: "update")
        guard let stored = returned.first else {
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    /// Deletes the model's row by primary key. Throws
    /// `HangarError.staleModel` if the row no longer exists.
    public func delete<M: Table>(_ model: M) async throws {
        let statement = try SQLRenderer.delete(model)
        let sequence = try await execute(statement.postgresQuery(), intent: .write, operation: "delete")
        var deleted = 0
        for try await _ in sequence { deleted += 1 }
        guard deleted > 0 else {
            throw HangarError.staleModel(table: M.schema.name)
        }
    }

    // MARK: Changeset writes — minimal, validated

    /// Inserts a validated changeset: only its changed fields appear in the
    /// INSERT; every other column falls to its database default. Throws
    /// `ChangesetValidationError` (from `validatedChanges`) before
    /// anything reaches the wire if the changeset is invalid.
    @discardableResult
    public func insert<M: Table>(_ changeset: Changeset<M>) async throws -> M {
        let validated = try changeset.validatedChanges()
        let returned: [M] = try await rows(for: SQLRenderer.insert(validated, into: M.self), intent: .write, operation: "insert")
        guard let stored = returned.first else {
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    /// Upsert: insert with `ON CONFLICT` behavior. With
    /// `.doUpdate`, the conflicting row is updated (only the `set` columns,
    /// from the incoming values) and returned. With `.doNothing`, a
    /// conflicting insert is skipped and the result is nil.
    @discardableResult
    public func insert<M: Table>(
        _ changeset: Changeset<M>, onConflict: OnConflict<M>
    ) async throws -> M? {
        let validated = try changeset.validatedChanges()
        let returned: [M] = try await rows(
            for: SQLRenderer.insert(validated, into: M.self, onConflict: onConflict),
            intent: .write, operation: "insert")
        return returned.first
    }

    /// Updates only the changeset's changed fields, addressed by the
    /// original's primary key — this is where dirty tracking pays off: an
    /// untouched column never appears in the SET clause. A changeset with
    /// no changes is a no-op and returns the original without a query.
    @discardableResult
    public func update<M: Table>(_ changeset: Changeset<M>) async throws -> M {
        let validated = try changeset.validatedChanges()
        guard validated.identity != nil else {
            throw HangarError.updateWithoutIdentity(table: M.schema.name)
        }
        if validated.changedFields.isEmpty, let original = changeset.original {
            return original
        }
        let returned: [M] = try await rows(for: SQLRenderer.update(validated, into: M.self), intent: .write, operation: "update")
        guard let stored = returned.first else {
            throw HangarError.staleModel(table: M.schema.name)
        }
        return stored
    }

    // MARK: Execution

    /// PostgresNIO's "logging disabled" for entry points that require a
    /// logger (`PostgresConnection.query`), matching what `nil` means on
    /// `PostgresClient`.
    static let quietLogger = Logger(
        label: "hangar.quiet", factory: { _ in SwiftLogNoOpLogHandler() })

    /// The one funnel to the wire: pooled client normally (routed by
    /// `intent` when a replica is configured), the transaction's own
    /// connection inside `transaction { }` — which is what makes a read
    /// inside a transaction see that transaction's uncommitted writes.
    ///
    /// Instrumentation lives here so every statement gets it:
    /// a debug log line with the SQL (placeholders only — values are binds
    /// and never appear), and a `hangar.query.duration` timer dimensioned
    /// by operation. The measured duration is dispatch-to-first-response;
    /// consuming a large result set costs extra and is not included.
    func execute(
        _ query: PostgresQuery, intent: Intent, operation: String
    ) async throws -> PostgresRowSequence {
        let start = ContinuousClock.now
        let sequence: PostgresRowSequence
        switch backend {
        case .client(let primary, let replica):
            let client = intent == .read ? (replica ?? primary) : primary
            sequence = try await client.query(query, logger: logger)
        case .transaction(let connection, _):
            sequence = try await connection.query(query, logger: logger ?? Self.quietLogger)
        }
        let duration = ContinuousClock.now - start
        Timer(
            label: "hangar.query.duration",
            dimensions: [("operation", operation)],
            preferredDisplayUnit: .milliseconds
        ).recordNanoseconds(nanoseconds(of: duration))
        logger?.debug(
            "hangar query",
            metadata: [
                "sql": .string(query.sql),
                "operation": .string(operation),
                "duration_ms": .stringConvertible(Double(nanoseconds(of: duration)) / 1e6),
            ])
        return sequence
    }

    private func nanoseconds(of duration: Duration) -> Int64 {
        Int64(duration.components.seconds &* 1_000_000_000)
            &+ Int64(duration.components.attoseconds / 1_000_000_000)
    }

    private func rows<R: RowDecodable>(
        for statement: RenderedStatement, intent: Intent, operation: String
    ) async throws -> [R] {
        let sequence = try await execute(statement.postgresQuery(), intent: intent, operation: operation)
        var results: [R] = []
        for try await row in sequence {
            results.append(try R(from: row))
        }
        return results
    }

    private func scalar<V: PostgresDecodable>(
        _ type: V.Type, for statement: RenderedStatement, table: String, operation: String
    ) async throws -> V {
        let sequence = try await execute(statement.postgresQuery(), intent: .read, operation: operation)
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(V.self, from: cells[0], table: table, column: "?column?")
        }
        throw HangarError.columnCountMismatch(table: table, expected: 1, got: 0)
    }
}

// MARK: - Ambient access

extension Repo {
    /// Binds `Repo.current` for the duration of `body` — Hangar owns the
    /// task-local; whoever manages lifetime populates it (a standalone user
    /// directly, Flight's adapter when opening a request scope).
    public static func with<T>(
        _ repo: Repo,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(repo) {
            try await body()
        }
    }

    /// The ambient repo, or a clear error naming the problem. Task-locals
    /// propagate to structured child tasks (`async let`, task groups) but
    /// **not** across `Task.detached` — and that is correct: a background
    /// job should not silently join a request's transaction.
    public static func require() throws -> Repo {
        guard let repo = current else {
            throw HangarError.noAmbientRepo
        }
        return repo
    }
}

extension Repo {
    @TaskLocal public static var current: Repo?
}
