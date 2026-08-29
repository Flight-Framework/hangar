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

    /// The `deleted_at IS [NOT] NULL` condition this scope implies for one
    /// source, or nil when the source has no `@Deleted` column or the scope
    /// asks for everything.
    ///
    /// `table` is the name the source is addressed by — the table name, or
    /// its alias where it has one; a join qualifies every reference, so
    /// getting this wrong would produce a condition against the wrong
    /// source rather than no condition at all.
    func condition(for column: ColumnDefinition?, qualifiedBy table: String) -> SQLExpression? {
        guard let column else { return nil }
        let reference = SQLExpression.column(table: table, name: column.name)
        switch self {
        case .excluded: return .isNull(reference)
        case .only: return .isNotNull(reference)
        case .included: return nil
        }
    }

    /// The scope a *joined* source gets, given this one on the base.
    ///
    /// A join's base scope answers "which base rows am I looking at"; the
    /// joined sides are looked *through*, and a deleted row on the far side
    /// of a join is no more visible than one on the near side. So `.only`
    /// — a trash view of files — still joins to live owners, while
    /// `.included` means "stop filtering on deletion in this query at all"
    /// and so lifts it everywhere. Documented in README's soft-delete
    /// section; pinned by `SoftDeleteJoinTests`.
    var forJoinedSource: DeletedRowScope {
        self == .included ? .included : .excluded
    }
}

/// ANDs two optional expressions — the shape every scope application needs,
/// where either side may be absent.
func andedExpressions(_ lhs: SQLExpression?, _ rhs: SQLExpression?) -> SQLExpression? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return .infix("AND", lhs, rhs)
}

/// ANDs a scope condition onto a predicate, when there is one to add.
func andedPredicate(_ predicate: Predicate?, _ condition: SQLExpression?) -> Predicate? {
    guard let combined = andedExpressions(predicate?.expression, condition) else { return nil }
    return Predicate(expression: combined)
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
        andedPredicate(
            predicate,
            deletedRows.condition(for: Model.schema.deletedAt, qualifiedBy: Model.schema.name))
    }
}

extension Table {
    /// Whether this entity has a `@Deleted` column.
    public static var isSoftDeletable: Bool { schema.deletedAt != nil }

    /// `Self.withDeleted()` — sugar for `all.withDeleted()`, so the scope
    /// reads the same at the head of a chain as `where`/`order`/`limit` do.
    public static func withDeleted() -> Query<Self, Self> {
        all.withDeleted()
    }

    /// `Self.onlyDeleted()` — sugar for `all.onlyDeleted()`: the trash-view
    /// spelling, `StoredFile.onlyDeleted().where { ... }`.
    public static func onlyDeleted() -> Query<Self, Self> {
        all.onlyDeleted()
    }
}
