import PostgresNIO

// Bulk update: `repo.update(query) { ... }` writes the same values to every
// row a predicate matches, in one statement. The assignment surface mirrors
// `.select {}`: a columns closure returning a tuple, each element typed
// against its column, arity handled by a parameter pack.

/// An opaque SET-clause fragment: public so `Assignable` can require it,
/// internal inside so the expression tree stays a Hangar implementation
/// detail. Not user-constructible.
public struct ColumnAssignment: Sendable {
    let name: String
    let expression: SQLExpression
}

/// One `column = value` pair in a bulk update's SET clause. Produced by
/// ``Column/set(to:)-. Conform nothing to this yourself.
public protocol Assignable: Sendable {
    var _assignment: ColumnAssignment { get }
}

/// A typed `column = value` assignment — `Value` is the column's type, so
/// assigning the wrong type is a compile error, exactly as comparing one is.
public struct Assignment<Value>: Sendable, Assignable {
    let name: String
    let expression: SQLExpression

    public var _assignment: ColumnAssignment {
        ColumnAssignment(name: name, expression: expression)
    }
}

extension Column where Value: ColumnCodable {
    /// `column = value`, for a bulk update's SET clause:
    ///
    /// ```swift
    /// try await repo.update(Post.where { $0.published == false }) {
    ///     ($0.published.set(to: true), $0.reviewedAt.set(to: Date()))
    /// }
    /// ```
    ///
    /// The value is always a bound parameter, never SQL text.
    public func set(to value: Value) -> Assignment<Value> {
        Assignment(name: name, expression: .bind(SQLBind(value)))
    }
}

extension Column {
    /// `column = value` for an optional column — `set(to: nil)` writes SQL
    /// NULL.
    public func set<V: ColumnCodable>(to value: V?) -> Assignment<V?> where Value == V? {
        Assignment(name: name, expression: .bind(SQLBind(value)))
    }
}
