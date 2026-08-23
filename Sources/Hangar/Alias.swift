// Table aliasing: the seam that makes self-joins expressible.
//
// A `Columns` struct normally bakes its entity's table name into every
// column. A self-join needs two *distinguishable* column sets over one
// table — `"parent"."id"` vs `"child"."id"` — and an alias is how SQL
// spells that. `Table.alias(_:)` produces a join source whose columns
// qualify with the alias instead of the table name.

/// The generated `Columns` contract: reconstructible under an override
/// table qualifier. `@Entity` generates the conformance; conform nothing
/// to this yourself.
public protocol AliasableColumns: Sendable {
    /// Every column of the entity, qualified with `table` instead of the
    /// entity's own table name.
    init(table: String)
}

/// A table under an alias, usable wherever a join takes a table:
///
/// ```swift
/// Employee.alias("manager").join(Employee.alias("report"),
///     on: { manager, report in report.managerID == manager.id })
/// ```
///
/// Both closures' column sets qualify with their alias, so the rendered
/// SQL reads `"employees" AS "manager" JOIN "employees" AS "report"` and
/// every column reference is unambiguous.
public struct Aliased<T: Table>: Sendable {
    /// The alias, exactly as it will appear (quoted) in `FROM ... AS`.
    let name: String

    /// The entity's columns, qualified with the alias.
    var columns: T.QueryColumns {
        T.QueryColumns(table: name)
    }
}

extension Table {
    /// This table under an alias, for joins — required for a self-join,
    /// allowed on any join where distinct names read better than table
    /// names.
    public static func alias(_ name: String) -> Aliased<Self> {
        Aliased(name: name)
    }
}
