/// Hangar's own failures — everything the library can detect before or after
/// the wire. PostgresNIO's errors (connection, server, cell-level decode)
/// pass through untouched; these describe the layer above.
public enum HangarError: Error, Sendable, CustomStringConvertible {
    /// `Repo.current` was read where no ambient repo is bound. Task-locals
    /// propagate to structured child tasks but not across `Task.detached` —
    /// a detached task must be handed a `Repo` explicitly (design §5.1).
    case noAmbientRepo

    /// `repo.one(...)` matched more than one row.
    case tooManyRows(table: String)

    /// An update or delete matched zero rows — the model's primary key no
    /// longer identifies a row (deleted concurrently, or never inserted).
    case staleModel(table: String)

    /// A row arrived with a different column count than the entity's
    /// decoder expects — the statement's column list and the Swift type
    /// disagree. With Phase-1 queries this indicates a schema/entity drift.
    case columnCountMismatch(table: String, expected: Int, got: Int)

    /// A cell failed to decode as the entity property's type. Wraps the
    /// underlying PostgresNIO error with the table/column it happened on.
    case columnDecoding(table: String, column: String, underlying: any Error)

    /// A Postgres enum value arrived that the Swift enum has no case for.
    case invalidEnumValue(type: String, value: String)

    /// A `@JSONB` column failed to encode or decode.
    case jsonb(table: String, column: String, underlying: any Error)

    /// An UPDATE was requested for a table whose every column is either
    /// primary key or database-generated — there is nothing to SET.
    case noUpdatableColumns(table: String)

    /// A changeset value could not be cast back to its column's static
    /// type — the changeset's TableModel metadata and the @Entity schema
    /// have diverged (impossible for macro-generated entities; possible
    /// with hand-rolled conformances).
    case changesetValueMismatch(table: String, column: String)

    /// `repo.update(changeset)` was given an insert changeset (no
    /// original, so no primary-key identity to address the row with).
    case updateWithoutIdentity(table: String)

    /// Two Multi steps share a name — results are keyed by name, so the
    /// second would silently shadow the first.
    case duplicateMultiStep(name: String)

    /// An unloaded association was accessed via `Loadable.get()` (design
    /// §7.3). Deterministic and loud, never a silent query.
    case notPreloaded(association: String)

    /// `.preload` was called with a keypath the entity's generated
    /// association metadata doesn't know, or the metadata couldn't resolve
    /// a foreign-key column — @Entity generates both sides, so this means
    /// the keypath isn't an association property.
    case unknownAssociation(table: String, association: String)

    /// A `@BelongsTo` preload found no related row for a non-nil foreign
    /// key — the reference dangles (row deleted without a constraint, or a
    /// racing delete between the two preload queries).
    case danglingBelongsTo(table: String, association: String)

    /// A `select(into:)` projection was malformed (unlabeled tuple, or a
    /// tuple element that isn't a column/aggregate), or a projected query
    /// reached execution without a selection.
    case invalidProjection(table: String, reason: String)

    /// A dynamic filter named a field outside the entity's allowlist
    /// (§9.1) — rejected, never interpolated.
    case unknownFilterField(table: String, field: String)

    /// A dynamic filter value's shape doesn't match its column's type
    /// (e.g. a string for an integer column).
    case invalidFilterValue(table: String, field: String)

    /// Internal invariant: the renderer asked a model for a column its
    /// generated `_bind(for:)` doesn't know. Thrown, not trapped — a bug in
    /// Hangar should fail one request, not the process (design §7.3).
    case unknownColumn(table: String, column: String)

    public var description: String {
        switch self {
        case .noAmbientRepo:
            return "No ambient Repo is bound on this task. Wrap the call in Repo.with(repo) { ... } — note that task-locals do not cross Task.detached."
        case .tooManyRows(let table):
            return "one(...) on \"\(table)\" matched more than one row; use all(...) or add a narrower predicate."
        case .staleModel(let table):
            return "The \"\(table)\" row for this model no longer exists — it was deleted concurrently or never inserted."
        case .columnCountMismatch(let table, let expected, let got):
            return "Decoding \"\(table)\": the row has \(got) columns but the entity expects \(expected) — the statement's column list and the @Entity type disagree."
        case .columnDecoding(let table, let column, let underlying):
            return "Decoding \"\(table)\".\"\(column)\" failed: \(underlying)"
        case .invalidEnumValue(let type, let value):
            return "Postgres sent \"\(value)\" for enum \(type), which has no such case — the database enum and the Swift enum have diverged."
        case .jsonb(let table, let column, let underlying):
            return "JSONB \"\(table)\".\"\(column)\" failed to encode/decode: \(underlying)"
        case .noUpdatableColumns(let table):
            return "update on \"\(table)\": every column is primary-key or database-generated — there is nothing to SET."
        case .changesetValueMismatch(let table, let column):
            return "changeset value for \"\(table)\".\"\(column)\" does not match the column's type — the TableModel metadata and the @Entity schema disagree."
        case .updateWithoutIdentity(let table):
            return "update(changeset) on \"\(table)\": the changeset has no original, so no primary key identifies the row. Build update changesets with Changeset(original:)."
        case .duplicateMultiStep(let name):
            return "Multi has two steps named \"\(name)\" — step names key the results and must be unique."
        case .notPreloaded(let association):
            return "Association \"\(association)\" was not preloaded. Add .preload(\\.\(association)) to the query that fetched this model."
        case .unknownAssociation(let table, let association):
            return "\"\(table)\" has no association metadata for \"\(association)\" — .preload takes a keypath to a @HasMany/@BelongsTo/@HasOne property."
        case .danglingBelongsTo(let table, let association):
            return "Preloading \"\(table)\".\(association): the foreign key references a row that does not exist — the reference dangles."
        case .invalidProjection(let table, let reason):
            return "Projection on \"\(table)\": \(reason)"
        case .unknownFilterField(let table, let field):
            return "\"\(field)\" is not a filterable field of \"\(table)\" — dynamic filters only reach columns listed in `filterable` (§9.1)."
        case .invalidFilterValue(let table, let field):
            return "The value for dynamic filter \"\(field)\" on \"\(table)\" doesn't match the column's type."
        case .unknownColumn(let table, let column):
            return "Internal error: entity \"\(table)\" has no binding for column \"\(column)\". This is a Hangar bug."
        }
    }
}
