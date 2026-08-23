/// A typed reference to one table column — what `$0.title` is inside a
/// `where`/`order` closure. `Value` is the Swift property
/// type; operators are constrained on it, which is what makes
/// `Column<Int> > "x"` a compile error.
///
/// `Value` is deliberately unconstrained on the type itself: a `@JSONB`
/// column is a `Column<SomeCodable>` that simply has no comparison
/// operators until the JSONB operator set arrives (Phase 4/5).
public struct Column<Value>: Sendable {
    public let name: String
    /// The owning table — used only in scopes where a statement touches
    /// more than one table (correlated subqueries, joins); single-table
    /// SQL stays unqualified.
    public let table: String

    public init(_ name: String, table: String = "") {
        self.name = name
        self.table = table
    }

    var expression: SQLExpression { .column(table: table, name: name) }
}

// MARK: - Ordering

/// One ORDER BY term: `$0.publishedAt.desc`. Carries the
/// column's table for multi-table scopes; single-table SQL renders it bare.
public struct OrderTerm: Sendable {
    public enum Direction: String, Sendable {
        case asc = "ASC"
        case desc = "DESC"
    }

    let table: String
    let column: String
    let direction: Direction
}

extension Column {
    public func asc() -> OrderTerm { OrderTerm(table: table, column: name, direction: .asc) }
    public func desc() -> OrderTerm { OrderTerm(table: table, column: name, direction: .desc) }
}
