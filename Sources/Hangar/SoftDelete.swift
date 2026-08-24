import Foundation

/// Which rows a query should see, for an entity that supports soft deletion.
///
/// Excluding deleted rows is the default because the alternative is worse: a
/// query that silently includes them is a bug that looks like working code
/// until someone notices deleted records in a list. Opting in is explicit and
/// visible at the call site.
public enum DeletedRowScope: Sendable, Equatable {
    /// Only rows that are not deleted. The default.
    case excluded
    /// Deleted and live rows together.
    case included
    /// Only deleted rows — for a trash view or an audit.
    case only
}

extension Query {
    /// Include soft-deleted rows in this query.
    ///
    ///     try await repo.all(Post.all.withDeleted())
    ///
    /// A no-op on an entity with no `@Deleted` column, so it is safe in
    /// generic code that does not know whether the model is soft-deletable.
    public func withDeleted() -> Query<Model, Result> {
        var next = self
        next.deletedRows = .included
        return next
    }

    /// Restrict this query to soft-deleted rows.
    public func onlyDeleted() -> Query<Model, Result> {
        var next = self
        next.deletedRows = .only
        return next
    }

    /// The caller's predicate, plus the soft-delete condition this query's
    /// scope implies.
    ///
    /// Every read path renders from this rather than from `predicate`, which
    /// is what makes the exclusion uniform: `select`, `count`, `exists`,
    /// set-based `update` and `delete`, and the subquery a preload issues all
    /// inherit it without each having to remember.
    var effectivePredicate: Predicate? {
        guard let column = Model.schema.deletedAt else { return predicate }
        let deletedColumn = SQLExpression.column(table: Model.schema.name, name: column.name)
        let scopeCondition: SQLExpression?
        switch deletedRows {
        case .excluded: scopeCondition = .isNull(deletedColumn)
        case .only: scopeCondition = .isNotNull(deletedColumn)
        case .included: scopeCondition = nil
        }
        guard let scopeCondition else { return predicate }
        guard let existing = predicate else { return Predicate(expression: scopeCondition) }
        return Predicate(expression: .infix("AND", existing.expression, scopeCondition))
    }
}

extension Table {
    /// Whether this entity has a `@Deleted` column.
    public static var isSoftDeletable: Bool { schema.deletedAt != nil }
}
