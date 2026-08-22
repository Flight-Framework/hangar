import Changesets
import PostgresNIO

/// Anything decodable from a Postgres row whose columns were rendered by
/// Hangar — cells are consumed positionally, exactly as the statement listed
/// them. `@Entity` types conform via their generated decoder; Phase 4's
/// `select(into:)` projections will conform independently.
public protocol RowDecodable: Sendable {
    init(from row: PostgresRow) throws
}

/// The conformance `@Entity` generates (design §4). Everything here is
/// macro-emitted; nothing is implemented by hand.
///
/// Refines `Changesets.TableModel` (design §11.2): every entity carries the
/// keypath→column metadata changesets validate against, so
/// `Changeset(Post.self)` and `repo.insert(changeset)` work out of the box.
/// TableModel's `columns` requirement is the `[TableColumn<Self>]` catalog;
/// Hangar's own column DSL lives under `queryColumns` — renamed from the
/// design doc's `columns` precisely to leave that slot to TableModel
/// (recorded in README).
public protocol Table: RowDecodable, TableModel {
    /// The generated struct with one typed `Column<T>` per stored property —
    /// what `where`/`order` closures receive.
    associatedtype QueryColumns: Sendable

    static var queryColumns: QueryColumns { get }
    static var schema: TableSchema { get }

    /// The bound parameter for one of this model's columns, by column name.
    /// `nil` only if asked for a column the entity doesn't have — an
    /// internal invariant violation the `Repo` converts to a thrown error.
    /// Underscored: generated, called by Hangar, not user API.
    func _bind(for column: String) -> SQLBind?

    /// The bound parameter for one column from a changeset's type-erased
    /// value (`ValidatedChanges` boxes values as `any Sendable`; the
    /// generated switch casts each back to its column's static type).
    /// `nil` when the cast fails or the column is unknown — the `Repo`
    /// converts either to a thrown error. Underscored: generated, not user
    /// API.
    static func _changesetBind(column: String, value: any Sendable) -> SQLBind?

    /// The association loader for one `@HasMany`/`@BelongsTo`/`@HasOne`
    /// property, keyed by its keypath (design §4, item 4 — the metadata
    /// that makes preload possible). Generated only for entities that
    /// declare associations; the default answers nil for everything.
    /// Erased to `any Sendable` here; `.preload` call sites cast back to
    /// the loader type they statically expect. Underscored: generated, not
    /// user API.
    static func _association(for keyPath: AnyKeyPath) -> (any Sendable)?
}

extension Table {
    public static func _association(for keyPath: AnyKeyPath) -> (any Sendable)? {
        nil
    }
}

/// Table metadata as the `@Entity` macro records it (design §4, item 3).
///
/// Everything derived — the key/insertable/updatable subsets and the
/// rendered column lists — is computed **once**, here, because a schema is
/// a `static let` per entity and these are otherwise recomputed on every
/// single query. (Benchmarks: filtering and re-quoting per query cost more
/// than the rest of rendering put together.)
public struct TableSchema: Sendable {
    public let name: String
    /// All columns, in declaration order — also the order every SELECT and
    /// RETURNING list is rendered in, and the order the decoder consumes.
    public let columns: [ColumnDefinition]

    public let primaryKey: [ColumnDefinition]
    /// Columns included in INSERT statements (everything the database
    /// doesn't generate itself).
    public let insertable: [ColumnDefinition]
    /// Columns included in UPDATE ... SET (insertable minus the key).
    public let updatable: [ColumnDefinition]

    /// `"table"` — the quoted table name.
    let quotedName: String
    /// `"a", "b", "c"` — every column, the SELECT and RETURNING list.
    let selectList: String
    /// `"table"."a", "table"."b"` — the same list qualified, for joins.
    let qualifiedSelectList: String
    /// `"a", "b"` — the insertable columns, for `INSERT INTO t (…)`.
    let insertList: String
    /// `$1, $2, …` for the insertable columns.
    let insertPlaceholders: String

    public init(name: String, columns: [ColumnDefinition]) {
        self.name = name
        self.columns = columns
        self.primaryKey = columns.filter(\.isPrimaryKey)
        self.insertable = columns.filter { !$0.isGenerated }
        self.updatable = columns.filter { !$0.isGenerated && !$0.isPrimaryKey }

        let quotedName = SQLRenderer.quote(name)
        self.quotedName = quotedName
        self.selectList = columns.map(\.quotedName).joined(separator: ", ")
        self.qualifiedSelectList = columns
            .map { "\(quotedName).\($0.quotedName)" }
            .joined(separator: ", ")
        self.insertList = insertable.map(\.quotedName).joined(separator: ", ")
        self.insertPlaceholders = (1...max(insertable.count, 1))
            .prefix(insertable.count)
            .map { "$\($0)" }
            .joined(separator: ", ")
    }
}

public struct ColumnDefinition: Sendable, Equatable {
    public let name: String
    public let isPrimaryKey: Bool
    /// `@ID(generated: true)`: the database produces the value (identity /
    /// serial / default); the column is excluded from INSERT lists and read
    /// back via RETURNING.
    public let isGenerated: Bool
    /// The name pre-quoted, so rendering never re-escapes it.
    let quotedName: String

    public init(name: String, isPrimaryKey: Bool = false, isGenerated: Bool = false) {
        self.name = name
        self.isPrimaryKey = isPrimaryKey
        self.isGenerated = isGenerated
        self.quotedName = SQLRenderer.quote(name)
    }

    public static func == (lhs: ColumnDefinition, rhs: ColumnDefinition) -> Bool {
        lhs.name == rhs.name && lhs.isPrimaryKey == rhs.isPrimaryKey
            && lhs.isGenerated == rhs.isGenerated
    }
}
