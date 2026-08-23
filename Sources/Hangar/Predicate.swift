/// The expression tree behind predicates. Values are always `SQLBind`
/// parameters — a value can never become SQL text.
indirect enum SQLExpression: Sendable {
    /// A column reference. `table` renders only in multi-table scopes
    /// (correlated subqueries, joins) — the writer decides.
    case column(table: String, name: String)
    case bind(SQLBind)
    /// `(lhs op rhs)` — comparison, AND/OR, LIKE/ILIKE.
    case infix(String, SQLExpression, SQLExpression)
    /// `(lhs = ANY(rhs))` — the batched-preload membership test (design
    /// ): one bound array parameter, however many keys.
    case anyOf(SQLExpression, SQLExpression)
    /// `name(args...)` — aggregates and, later, arbitrary functions.
    case function(String, [SQLExpression])
    /// `(operand)::type` — dialect-accommodation casts (integer sum →
    /// bigint, avg → float8). The type string is always Hangar-authored,
    /// never user input.
    case cast(SQLExpression, String)
    /// `(lhs IN (SELECT...))` — an uncorrelated subquery. The
    /// rendered inner statement shares the outer writer's placeholder
    /// numbering.
    case inSubquery(SQLExpression, SubquerySQL)
    /// `EXISTS (SELECT 1...)` — a possibly-correlated subquery;
    /// rendered with qualified column references throughout, since inner
    /// and outer tables coexist in one scope.
    case existsSubquery(SubquerySQL)
    /// A safe raw fragment: literal SQL text interleaved
    /// with bound values — see `SQLFragment`.
    case fragment([SQLFragment.Part])
    /// `NOT (operand)`
    case not(SQLExpression)
    case isNull(SQLExpression)
    case isNotNull(SQLExpression)
}

/// A boolean SQL expression — what `where` accepts and operators produce.
/// Deliberately not `Bool`, which is why overloading `&&`/`||` on it resolves
/// cleanly against the standard library's short-circuiting operators
/// (the design; the overload question is pinned by PredicateSpikeTests).
public struct Predicate: Sendable {
    let expression: SQLExpression
}

/// Anything usable where a predicate is expected. `Predicate` itself
/// conforms, and so does `Column<Bool>` — which is what makes the bare
/// `Post.where { $0.published }` spelling work.
public protocol PredicateConvertible: Sendable {
    var predicate: Predicate { get }
}

extension Predicate: PredicateConvertible {
    /// A predicate is trivially predicate-convertible — identity.
    public var predicate: Predicate { self }
}

extension Column: PredicateConvertible where Value == Bool {
    /// A boolean column stands alone as a predicate: `.where { $0.published }`.
    public var predicate: Predicate { Predicate(expression: expression) }
}

// MARK: - Comparison operators

/// `column = value` — the value is always a bound parameter.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <> value`.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, .bind(SQLBind(rhs))))
}

/// Optional columns: comparing against `nil` renders `IS NULL` /
/// `IS NOT NULL` — never `= NULL`, which matches nothing.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V?>, rhs: V?) -> Predicate {
    guard let rhs else { return Predicate(expression: .isNull(lhs.expression)) }
    return Predicate(expression: .infix("=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <> value` for an optional column; `!= nil` renders `IS NOT NULL`.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V?>, rhs: V?) -> Predicate {
    guard let rhs else { return Predicate(expression: .isNotNull(lhs.expression)) }
    return Predicate(expression: .infix("<>", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column < value`.
public func < <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column > value`.
public func > <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column <= value`.
public func <= <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix("<=", lhs.expression, .bind(SQLBind(rhs))))
}

/// `column >= value`.
public func >= <V: ColumnCodable & Comparable>(lhs: Column<V>, rhs: V) -> Predicate {
    Predicate(expression: .infix(">=", lhs.expression, .bind(SQLBind(rhs))))
}

// MARK: - Boolean combinators (the spike surface)

/// Both predicates — renders `(lhs AND rhs)`, fully parenthesized.
public func && (lhs: some PredicateConvertible, rhs: some PredicateConvertible) -> Predicate {
    Predicate(expression: .infix("AND", lhs.predicate.expression, rhs.predicate.expression))
}

/// Either predicate — renders `(lhs OR rhs)`, fully parenthesized.
public func || (lhs: some PredicateConvertible, rhs: some PredicateConvertible) -> Predicate {
    Predicate(expression: .infix("OR", lhs.predicate.expression, rhs.predicate.expression))
}

public prefix func ! (operand: some PredicateConvertible) -> Predicate {
    Predicate(expression: .not(operand.predicate.expression))
}

// MARK: - Column-to-column comparisons (correlated subqueries and joins)

/// Column-to-column equality — the join-condition shape: `c.postID == p.id`.
public func == <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("=", lhs.expression, rhs.expression))
}

/// Column-to-column inequality.
public func != <V: ColumnCodable & Equatable>(lhs: Column<V>, rhs: Column<V>) -> Predicate {
    Predicate(expression: .infix("<>", lhs.expression, rhs.expression))
}

// MARK: - Membership

extension Column where Value: ColumnCodable & PostgresArrayEncodable {
    /// Membership in a value list — rendered `= ANY($1)`: one bound array
    /// parameter, however many values.
    public func `in`(_ values: [Value]) -> Predicate {
        Predicate(expression: .anyOf(expression, .bind(SQLBind { try $0.append(values) })))
    }
}

extension Column {
    /// Membership in an uncorrelated subquery — because a query is a
    /// value, the inner SELECT nests with no special mechanism, and its
    /// binds share the outer statement's numbering:
    ///
    /// ```swift
    /// let activeAuthors = Author.where { $0.name != "" }.select { $0.id }
    /// Post.where { $0.authorID.in(activeAuthors) }
    /// ```
    ///
    /// The subquery's Result must match this column's type — enforced by
    /// the signature.
    public func `in`<M2: Table>(_ subquery: Query<M2, Value>) -> Predicate {
        Predicate(
            expression: .inSubquery(
                expression,
                SubquerySQL { writer in
                    SQLRenderer.selectText(subquery, writer: &writer)
                }))
    }
}

extension Query {
    /// This query as a correlated `EXISTS` predicate — the closure
    /// that built it may reference the *outer* query's columns, because a
    /// query is just an expression tree:
    ///
    /// ```swift
    /// Post.where { p in
    ///     Comment.where { $0.postID == p.id && $0.body != "" }.exists
    /// }
    /// ```
    ///
    /// Inside the EXISTS scope every column renders table-qualified, since
    /// inner and outer tables share one namespace.
    public func exists() -> Predicate {
        let query = self
        return Predicate(
            expression: .existsSubquery(
                SubquerySQL { writer in
                    SQLRenderer.existsText(query, writer: &writer)
                }))
    }
}

// MARK: - Pattern matching

extension Column where Value == String {
    /// `column LIKE pattern` — `%` and `_` are the wildcards.
    public func like(_ pattern: String) -> Predicate {
        Predicate(expression: .infix("LIKE", expression, .bind(SQLBind(pattern))))
    }

    /// Postgres-only case-insensitive LIKE — first-class
    public func ilike(_ pattern: String) -> Predicate {
        Predicate(expression: .infix("ILIKE", expression, .bind(SQLBind(pattern))))
    }
}

extension Column where Value == String? {
    /// `column LIKE pattern` — `%` and `_` are the wildcards.
    public func like(_ pattern: String) -> Predicate {
        Predicate(expression: .infix("LIKE", expression, .bind(SQLBind(pattern))))
    }

    /// `column ILIKE pattern` — Postgres's case-insensitive LIKE.
    public func ilike(_ pattern: String) -> Predicate {
        Predicate(expression: .infix("ILIKE", expression, .bind(SQLBind(pattern))))
    }
}
