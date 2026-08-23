import Changesets
import PostgresNIO

// Joins. A joined query is still a value; its closures
// receive both tables' columns, and every column renders table-qualified
// because two tables share one namespace.
//
// Semantics follow Ecto: a join without a `.select {}` returns the *base*
// entity's rows (the join exists to filter or to feed aggregates);
// row pairs and cross-table shapes come from an explicit projection —
// which is what the design's  example does with `select(into:)`.

enum JoinKind: String, Sendable {
    case inner = "JOIN"
    case left = "LEFT JOIN"
}

/// A two-table query: `A` joined to `B`. `Result` defaults to `A`;
/// `.select {}` changes it, exactly as on `Query`.
public struct JoinedQuery<A: Table, B: Table, Result: Sendable>: Sendable {
    var kind: JoinKind
    var onPredicate: Predicate
    var predicate: Predicate? = nil
    var orderings: [OrderTerm] = []
    var grouping: [SQLExpression] = []
    var having: Predicate? = nil
    var rowLimit: Int? = nil
    var rowOffset: Int? = nil
    var isDistinct = false
    var rowLock: RowLock? = nil
    /// Preloads apply when `Result == A` (the base-entity path).
    var preloads: [PreloadStep<A>] = []
    var selection: Selection<Result>? = nil

    func rebinding<NewResult>(to selection: Selection<NewResult>) -> JoinedQuery<A, B, NewResult> {
        var next = JoinedQuery<A, B, NewResult>(kind: kind, onPredicate: onPredicate)
        next.predicate = predicate
        next.orderings = orderings
        next.grouping = grouping
        next.having = having
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.isDistinct = isDistinct
        next.rowLock = rowLock
        next.selection = selection
        return next
    }
}

// MARK: - Entry points

extension Table {
    /// `FROM Self JOIN other ON...` — inner join; rows of `Self` that
    /// have a match.
    public static func join<B: Table>(
        _ other: B.Type,
        on condition: (QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Self, B, Self> {
        JoinedQuery(kind: .inner, onPredicate: condition(queryColumns, B.queryColumns))
    }

    /// `FROM Self LEFT JOIN other ON...` — every row of `Self`, matched
    /// or not; the shape aggregates over optional children want.
    public static func leftJoin<B: Table>(
        _ other: B.Type,
        on condition: (QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Self, B, Self> {
        JoinedQuery(kind: .left, onPredicate: condition(queryColumns, B.queryColumns))
    }
}

extension Query {
    /// Joins another table onto an already-composed single-table query;
    /// accumulated conditions, ordering, limits, and preloads carry over.
    public func join<B: Table>(
        _ other: B.Type,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Result> where Result == Model {
        joined(.inner, other, condition)
    }

    public func leftJoin<B: Table>(
        _ other: B.Type,
        on condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Result> where Result == Model {
        joined(.left, other, condition)
    }

    private func joined<B: Table>(
        _ kind: JoinKind,
        _ other: B.Type,
        _ condition: (Model.QueryColumns, B.QueryColumns) -> Predicate
    ) -> JoinedQuery<Model, B, Model> where Result == Model {
        var next = JoinedQuery<Model, B, Model>(
            kind: kind, onPredicate: condition(Model.queryColumns, B.queryColumns))
        next.predicate = predicate
        next.orderings = orderings
        // Grouping and having were omitted here, so `Post.groupBy { … }.join(…)`
        // silently produced an ungrouped, unfiltered query — no error, just the
        // wrong rows. Composition order must not change the result.
        next.grouping = grouping
        next.having = having
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.isDistinct = isDistinct
        // A lock composed before the join carries through — dropping it
        // silently would leave rows unlocked that the caller asked to lock.
        next.rowLock = rowLock
        next.preloads = preloads
        return next
    }
}

// MARK: - Composition (two-column-set closures)

extension JoinedQuery {
    public func `where`(
        _ build: (A.QueryColumns, B.QueryColumns) -> some PredicateConvertible
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        let added = build(A.queryColumns, B.queryColumns).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    public func order(
        _ build: (A.QueryColumns, B.QueryColumns) -> OrderTerm
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        next.orderings.append(build(A.queryColumns, B.queryColumns))
        return next
    }

    public func groupBy<V>(
        _ build: (A.QueryColumns, B.QueryColumns) -> Column<V>
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        next.grouping.append(build(A.queryColumns, B.queryColumns).expression)
        return next
    }

    public func having(
        _ build: (A.QueryColumns, B.QueryColumns) -> some PredicateConvertible
    ) -> JoinedQuery<A, B, Result> {
        var next = self
        let added = build(A.queryColumns, B.queryColumns).predicate
        if let existing = next.having {
            next.having = Predicate(expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.having = added
        }
        return next
    }

    public func limit(_ count: Int) -> JoinedQuery<A, B, Result> {
        var next = self
        next.rowLimit = count
        return next
    }

    public func offset(_ count: Int) -> JoinedQuery<A, B, Result> {
        var next = self
        next.rowOffset = count
        return next
    }

    public func distinct() -> JoinedQuery<A, B, Result> {
        var next = self
        next.isDistinct = true
        return next
    }

    /// Typed projection over both tables — the same  pack surface as
    /// single-table `select`.
    public func select<each S: Selectable>(
        _ build: (A.QueryColumns, B.QueryColumns) -> (repeat each S)
    ) -> JoinedQuery<A, B, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        let selected = build(A.queryColumns, B.queryColumns)
        var items: [(expression: SQLExpression, alias: String?)] = []
        for item in repeat each selected {
            items.append((item._selectFragment.expression, nil))
        }
        let expected = items.count
        let table = A.schema.name
        return rebinding(
            to: Selection(items: items, invalid: nil) { row in
                let cells = row.makeRandomAccess()
                try _checkColumnCount(cells.count, expected: expected, table: table)
                var index = 0
                func next<T: PostgresDecodable>(_ type: T.Type) throws -> T {
                    defer { index += 1 }
                    return try _decodeColumn(T.self, from: cells[index], table: table, column: "#\(index)")
                }
                return (repeat try next((each S).Value.self))
            })
    }

    /// Projection into a named `Decodable` type over both tables — the
    /// design's  example:
    ///
    /// ```swift
    /// Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
    ///.groupBy { p, _ in p.id }
    ///.select(into: PostSummary.self) { p, c in
    ///         (id: p.id, title: p.title, commentCount: c.id.count)
    ///     }
    /// ```
    public func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (A.QueryColumns, B.QueryColumns) -> Fields
    ) -> JoinedQuery<A, B, T> {
        let fields = build(A.queryColumns, B.queryColumns)
        var items: [(expression: SQLExpression, alias: String?)] = []
        var invalid: HangarError?
        let mirror = Mirror(reflecting: fields)
        if mirror.displayStyle == .tuple, !mirror.children.isEmpty {
            for child in mirror.children {
                guard let label = child.label, !label.hasPrefix(".") else {
                    invalid = .invalidProjection(
                        table: A.schema.name,
                        reason: "select(into:) needs a label on every tuple element — labels become the columns \(T.self) decodes by.")
                    break
                }
                guard let selectable = child.value as? any Selectable else {
                    invalid = .invalidProjection(
                        table: A.schema.name,
                        reason: "select(into:) tuple element '\(label)' is not a column or aggregate expression.")
                    break
                }
                items.append((selectable._selectFragment.expression, label))
            }
        } else {
            invalid = .invalidProjection(
                table: A.schema.name,
                reason: "select(into:) takes a labeled tuple of at least two columns/aggregates.")
        }
        return rebinding(
            to: Selection(items: items, invalid: invalid) { row in
                try T(from: ProjectionDecoder(row: row.makeRandomAccess(), table: A.schema.name))
            })
    }
}

// MARK: - Rendering

extension SQLRenderer {
    static func select<A, B, R>(_ query: JoinedQuery<A, B, R>) throws -> RenderedStatement {
        guard A.schema.name != B.schema.name else {
            throw HangarError.invalidProjection(
                table: A.schema.name,
                reason: "self-joins need table aliases, which Hangar does not support yet.")
        }
        var writer = BindWriter()
        writer.qualified = true
        let list: String
        if let selection = query.selection {
            list = selection.items
                .map { item in
                    let rendered = SQLRenderer.render(item.expression, writer: &writer)
                    return item.alias.map { "\(rendered) AS \(quote($0))" } ?? rendered
                }
                .joined(separator: ", ")
        } else {
            // The base entity's columns, qualified — decoded by A's
            // generated positional decoder exactly as in a single-table
            // fetch.
            list = A.schema.qualifiedSelectList
        }
        var sql = "SELECT \(query.isDistinct ? "DISTINCT " : "")\(list)"
        sql += " FROM \(A.schema.quotedName) \(query.kind.rawValue) \(B.schema.quotedName)"
        sql += " ON \(SQLRenderer.render(query.onPredicate.expression, writer: &writer))"
        SQLRenderer.appendWhere(query.predicate, to: &sql, writer: &writer)
        if !query.grouping.isEmpty {
            let terms = query.grouping.map { SQLRenderer.render($0, writer: &writer) }.joined(separator: ", ")
            sql += " GROUP BY \(terms)"
        }
        if let having = query.having {
            sql += " HAVING \(SQLRenderer.render(having.expression, writer: &writer))"
        }
        if !query.orderings.isEmpty {
            let terms = query.orderings
                .map { "\(quote($0.table)).\(quote($0.column)) \($0.direction.rawValue)" }
                .joined(separator: ", ")
            sql += " ORDER BY \(terms)"
        }
        if let limit = query.rowLimit { sql += " LIMIT \(limit)" }
        if let offset = query.rowOffset { sql += " OFFSET \(offset)" }
        // Postgres itself rejects the invalid combinations loudly (FOR
        // UPDATE on the nullable side of an outer join, with GROUP BY...).
        if let lock = query.rowLock { sql += " \(lock.rawValue)" }
        return RenderedStatement(sql: sql, binds: writer.binds)
    }
}

// MARK: - Execution

extension Repo {
    /// Base-entity fetch through a join: decodes `A` rows, then runs any
    /// carried preloads.
    public func all<A: Table, B: Table>(_ query: JoinedQuery<A, B, A>) async throws -> [A] {
        let sequence = try await execute(SQLRenderer.select(query).postgresQuery(), intent: query.rowLock == nil ? .read : .write, operation: "select")
        var models: [A] = []
        for try await row in sequence {
            models.append(try A(from: row))
        }
        for step in query.preloads {
            try await step.run(&models, self)
        }
        return models
    }

    public func all<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> [R] {
        guard let selection = query.selection else {
            throw HangarError.invalidProjection(
                table: A.schema.name,
                reason: "the joined query's Result is not \(A.self) but no .select {} installed a projection — this is a Hangar bug.")
        }
        if let invalid = selection.invalid {
            throw invalid
        }
        let sequence = try await execute(SQLRenderer.select(query).postgresQuery(), intent: query.rowLock == nil ? .read : .write, operation: "select")
        var results: [R] = []
        for try await row in sequence {
            results.append(try selection.decode(row))
        }
        return results
    }

    public func one<A: Table, B: Table>(_ query: JoinedQuery<A, B, A>) async throws -> A? {
        let results = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: A.schema.name)
        }
        return results.first
    }

    public func one<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> R? {
        let results: [R] = try await all(query.limit(2))
        guard results.count <= 1 else {
            throw HangarError.tooManyRows(table: A.schema.name)
        }
        return results.first
    }

    /// How many joined rows match — note that with a one-to-many join this
    /// counts matches, not distinct base rows.
    public func count<A, B, R>(_ query: JoinedQuery<A, B, R>) async throws -> Int {
        var writer = BindWriter()
        writer.qualified = true
        var sql = "SELECT count(*) FROM \(A.schema.quotedName) \(query.kind.rawValue) \(B.schema.quotedName)"
        sql += " ON \(SQLRenderer.render(query.onPredicate.expression, writer: &writer))"
        if let predicate = query.predicate {
            sql += " WHERE \(SQLRenderer.render(predicate.expression, writer: &writer))"
        }
        let statement = RenderedStatement(sql: sql, binds: writer.binds)
        let sequence = try await execute(statement.postgresQuery(), intent: .read, operation: "count")
        for try await row in sequence {
            let cells = row.makeRandomAccess()
            return try _decodeColumn(Int.self, from: cells[0], table: A.schema.name, column: "count")
        }
        throw HangarError.columnCountMismatch(table: A.schema.name, expected: 1, got: 0)
    }

    private func quote(_ identifier: String) -> String {
        SQLRenderer.quote(identifier)
    }
}
