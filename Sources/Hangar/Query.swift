/// An immutable query value (design §3). Every operator returns a new
/// `Query`; nothing mutates. `Model` fixes which columns are addressable;
/// `Result` is what a row decodes to — always `Model` in Phase 1, changed by
/// `.select {}` when projections arrive (Phase 4).
public struct Query<Model: Table, Result: Sendable>: Sendable {
    var predicate: Predicate?
    var orderings: [OrderTerm] = []
    var rowLimit: Int?
    var rowOffset: Int?
    /// Pending association preloads (§7.2), executed by `Repo.all` after
    /// the parent rows decode. Carried on the query, applied only when the
    /// query produces full models.
    var preloads: [PreloadStep<Model>] = []
    /// GROUP BY expressions and the HAVING predicate (§6.1).
    var grouping: [SQLExpression] = []
    var having: Predicate?
    var isDistinct = false
    /// Installed by `.select {}` (§6): the SELECT list plus the row
    /// decoder for `Result`. Nil means "whole model" — every schema column
    /// in order, decoded by the generated `init(from:)`.
    var selection: Selection<Result>?

    init() {}

    /// The projection pivot: a new query over the same clauses with a
    /// different `Result`. Preloads are deliberately dropped — projections
    /// don't carry models to hang associations on.
    func rebinding<NewResult>(to selection: Selection<NewResult>) -> Query<Model, NewResult> {
        var next = Query<Model, NewResult>()
        next.predicate = predicate
        next.orderings = orderings
        next.rowLimit = rowLimit
        next.rowOffset = rowOffset
        next.grouping = grouping
        next.having = having
        next.isDistinct = isDistinct
        next.selection = selection
        return next
    }
}

// MARK: - Entry points on the entity type

extension Table {
    /// The unfiltered query: `repo.all(Post.all)`.
    public static var all: Query<Self, Self> { Query() }

    public static func `where`(
        _ build: (QueryColumns) -> some PredicateConvertible
    ) -> Query<Self, Self> {
        all.where(build)
    }

    public static func order(_ build: (QueryColumns) -> OrderTerm) -> Query<Self, Self> {
        all.order(build)
    }

    public static func limit(_ count: Int) -> Query<Self, Self> {
        all.limit(count)
    }

    public static func select<each S: Selectable>(
        _ build: (QueryColumns) -> (repeat each S)
    ) -> Query<Self, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        all.select(build)
    }

    public static func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (QueryColumns) -> Fields
    ) -> Query<Self, T> {
        all.select(into: type, build)
    }

    public static func groupBy<V>(_ build: (QueryColumns) -> Column<V>) -> Query<Self, Self> {
        all.groupBy(build)
    }
}

// MARK: - Composition operators (design §3.2 — all pure)

extension Query {
    /// Adds a condition, AND-combined with any existing ones — chained
    /// `where` calls narrow the result, which is what makes conditional
    /// composition work (design §9).
    public func `where`(
        _ build: (Model.QueryColumns) -> some PredicateConvertible
    ) -> Query<Model, Result> {
        var next = self
        let added = build(Model.queryColumns).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(
                expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    /// Adds a condition OR-combined with everything accumulated so far
    /// (Ecto's `or_where`): `(existing) OR (added)`.
    public func orWhere(
        _ build: (Model.QueryColumns) -> some PredicateConvertible
    ) -> Query<Model, Result> {
        var next = self
        let added = build(Model.queryColumns).predicate
        if let existing = next.predicate {
            next.predicate = Predicate(
                expression: .infix("OR", existing.expression, added.expression))
        } else {
            next.predicate = added
        }
        return next
    }

    /// Appends an ORDER BY term; chained calls order by multiple columns in
    /// call order.
    public func order(_ build: (Model.QueryColumns) -> OrderTerm) -> Query<Model, Result> {
        var next = self
        next.orderings.append(build(Model.queryColumns))
        return next
    }

    public func limit(_ count: Int) -> Query<Model, Result> {
        var next = self
        next.rowLimit = count
        return next
    }

    /// SELECT DISTINCT (§3.2). `distinctOn` arrives with the join pass.
    public func distinct() -> Query<Model, Result> {
        var next = self
        next.isDistinct = true
        return next
    }

    /// Appends a GROUP BY column; chained calls group by several (§6.1).
    public func groupBy<V>(_ build: (Model.QueryColumns) -> Column<V>) -> Query<Model, Result> {
        var next = self
        next.grouping.append(build(Model.queryColumns).expression)
        return next
    }

    /// HAVING over aggregate expressions; chained calls AND-combine:
    /// `.groupBy { $0.authorID }.having { $0.viewCount.sum() > 100 }`.
    public func having(
        _ build: (Model.QueryColumns) -> some PredicateConvertible
    ) -> Query<Model, Result> {
        var next = self
        let added = build(Model.queryColumns).predicate
        if let existing = next.having {
            next.having = Predicate(expression: .infix("AND", existing.expression, added.expression))
        } else {
            next.having = added
        }
        return next
    }

    // MARK: Projections (§6) — select changes Result

    /// Typed projection of one or more columns/aggregates. This is the
    /// §6.3 parameter-pack surface — one signature covers every arity:
    ///
    /// ```swift
    /// let ids:   [UUID]           = try await repo.all(Post.select { $0.id })
    /// let pairs: [(UUID, String)] = try await repo.all(Post.select { ($0.id, $0.title) })
    /// ```
    public func select<each S: Selectable>(
        _ build: (Model.QueryColumns) -> (repeat each S)
    ) -> Query<Model, (repeat (each S).Value)>
    where repeat (each S).Value: PostgresDecodable & Sendable {
        let selected = build(Model.queryColumns)
        var items: [(expression: SQLExpression, alias: String?)] = []
        for item in repeat each selected {
            items.append((item._selectFragment.expression, nil))
        }
        let expected = items.count
        let table = Model.schema.name
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

    /// Projection into a named `Decodable` type (§6). The closure returns a
    /// **labeled** tuple; each label becomes the column's SQL alias and the
    /// key the type decodes by:
    ///
    /// ```swift
    /// struct PostCount: Decodable { let authorID: UUID; let posts: Int }
    /// Post.groupBy { $0.authorID }
    ///     .select(into: PostCount.self) { (authorID: $0.authorID, posts: $0.id.count()) }
    /// ```
    public func select<T: Decodable & Sendable, Fields>(
        into type: T.Type,
        _ build: (Model.QueryColumns) -> Fields
    ) -> Query<Model, T> {
        let fields = build(Model.queryColumns)
        var items: [(expression: SQLExpression, alias: String?)] = []
        var invalid: HangarError?
        let mirror = Mirror(reflecting: fields)
        if mirror.displayStyle == .tuple, !mirror.children.isEmpty {
            for child in mirror.children {
                guard let label = child.label, !label.hasPrefix(".") else {
                    invalid = .invalidProjection(
                        table: Model.schema.name,
                        reason: "select(into:) needs a label on every tuple element — labels become the columns \(T.self) decodes by.")
                    break
                }
                guard let selectable = child.value as? any Selectable else {
                    invalid = .invalidProjection(
                        table: Model.schema.name,
                        reason: "select(into:) tuple element '\(label)' is not a column or aggregate expression.")
                    break
                }
                items.append((selectable._selectFragment.expression, label))
            }
        } else {
            invalid = .invalidProjection(
                table: Model.schema.name,
                reason: "select(into:) takes a labeled tuple of at least two columns/aggregates, e.g. { (id: $0.id, total: $0.viewCount.sum()) }.")
        }
        return rebinding(
            to: Selection(items: items, invalid: invalid) { row in
                try T(from: ProjectionDecoder(row: row.makeRandomAccess(), table: Model.schema.name))
            })
    }

    public func offset(_ count: Int) -> Query<Model, Result> {
        var next = self
        next.rowOffset = count
        return next
    }
}
