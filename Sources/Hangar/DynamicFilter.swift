import Foundation

// Runtime-sourced filters — the one deliberate safety
// tradeoff, made explicit. Filters arriving as JSON from a client can't be
// compile-checked, so they pass through an opt-in allowlist:
//
// ```swift
// extension Post: DynamicallyFilterable {
//     static let filterable: [String: AnyColumn<Post>] = [
//         "title":.init(\.title),
//         "published":.init(\.published),
//         "view_count":.init(\.viewCount),
//     ]   // authorID deliberately absent — not client-filterable
// }
//
// let query = try Post.where(dynamic: clientFilters)   // throws on unknown field
// ```
//
// **Non-negotiable rule:** a field name from an untrusted source is *never*
// interpolated into SQL. It is looked up in the allowlist and resolved to a
// known column, or the request is rejected. Values are always bound
// parameters. Opting a column into `filterable` is a deliberate decision
// to expose it.

/// A filter value as it arrives from the outside world — JSON-shaped.
/// `Decodable`, so `[String: DynamicFilterValue]` decodes directly from a
/// request body.
public enum DynamicFilterValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A filter value must be a JSON scalar (string, number, boolean, or null)."))
        }
    }
}

extension DynamicFilterValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// A column type that knows how to interpret a dynamic filter value —
/// strictly: a mismatched shape is a rejection (`nil`), never a coercion
/// surprise.
public protocol DynamicFilterConvertible: ColumnCodable, Equatable {
    static func fromDynamicFilter(_ value: DynamicFilterValue) -> Self?
}

extension String: DynamicFilterConvertible {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> String? {
        if case .string(let string) = value { return string }
        return nil
    }
}

extension Int: DynamicFilterConvertible {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> Int? {
        if case .int(let int) = value { return int }
        return nil
    }
}

extension Double: DynamicFilterConvertible {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> Double? {
        switch value {
        case .double(let double): return double
        case .int(let int): return Double(int)  // JSON doesn't distinguish 3 from 3.0
        default: return nil
        }
    }
}

extension Bool: DynamicFilterConvertible {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> Bool? {
        if case .bool(let bool) = value { return bool }
        return nil
    }
}

extension UUID: DynamicFilterConvertible {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> UUID? {
        if case .string(let string) = value { return UUID(uuidString: string) }
        return nil
    }
}

extension Date: DynamicFilterConvertible {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> Date? {
        if case .string(let string) = value {
            return try? Date(string, strategy: .iso8601)
        }
        return nil
    }
}

/// One-line opt-in for `PostgresEnum` columns:
/// `extension Status: DynamicFilterConvertible {}` — the label string maps
/// through `init(rawValue:)`.
extension DynamicFilterConvertible where Self: PostgresEnum {
    public static func fromDynamicFilter(_ value: DynamicFilterValue) -> Self? {
        if case .string(let string) = value { return Self(rawValue: string) }
        return nil
    }
}

/// One allowlisted column: a typed keypath erased behind a closure
/// that turns a dynamic value into a bound equality predicate. The keypath
/// is the compile-checked half; the closure captures its column name and
/// value type, so the string world never reaches SQL.
public struct AnyColumn<M: Table>: Sendable {
    let predicate: @Sendable (_ field: String, _ value: DynamicFilterValue) throws -> Predicate

    public init<V: DynamicFilterConvertible>(_ keyPath: KeyPath<M, V> & Sendable) {
        self.predicate = { field, value in
            guard let column = M.columnName(for: keyPath) else {
                throw HangarError.unknownColumn(table: M.schema.name, column: field)
            }
            guard let typed = V.fromDynamicFilter(value) else {
                throw HangarError.invalidFilterValue(table: M.schema.name, field: field)
            }
            return Predicate(
                expression: .infix(
                    "=", .column(table: M.schema.name, name: column), .bind(SQLBind(typed))))
        }
    }

    /// Optional columns additionally accept `null`, which filters as
    /// `IS NULL` — never `= NULL`, which matches nothing.
    public init<V: DynamicFilterConvertible>(_ keyPath: KeyPath<M, V?> & Sendable) {
        self.predicate = { field, value in
            guard let column = M.columnName(for: keyPath) else {
                throw HangarError.unknownColumn(table: M.schema.name, column: field)
            }
            if case .null = value {
                return Predicate(expression: .isNull(.column(table: M.schema.name, name: column)))
            }
            guard let typed = V.fromDynamicFilter(value) else {
                throw HangarError.invalidFilterValue(table: M.schema.name, field: field)
            }
            return Predicate(
                expression: .infix(
                    "=", .column(table: M.schema.name, name: column), .bind(SQLBind(typed))))
        }
    }
}

/// Opting an entity into runtime-sourced filtering. The allowlist is
/// the entire attack surface: fields absent from it don't exist as far as
/// dynamic filters are concerned.
public protocol DynamicallyFilterable: Table {
    static var filterable: [String: AnyColumn<Self>] { get }
}

extension DynamicallyFilterable {
    /// Builds an AND of equality filters from untrusted field/value pairs.
    /// Throws `HangarError.unknownFilterField` for a field outside the
    /// allowlist and `.invalidFilterValue` for a value whose shape doesn't
    /// match the column's type. Filters apply in field order, so the SQL is
    /// deterministic.
    public static func `where`(
        dynamic filters: [String: DynamicFilterValue]
    ) throws -> Query<Self, Self> {
        try all.where(dynamic: filters)
    }
}

extension Query where Model: DynamicallyFilterable {
    public func `where`(
        dynamic filters: [String: DynamicFilterValue]
    ) throws -> Query<Model, Result> {
        var next = self
        for (field, value) in filters.sorted(by: { $0.key < $1.key }) {
            guard let column = Model.filterable[field] else {
                throw HangarError.unknownFilterField(table: Model.schema.name, field: field)
            }
            let added = try column.predicate(field, value)
            if let existing = next.predicate {
                next.predicate = Predicate(
                    expression: .infix("AND", existing.expression, added.expression))
            } else {
                next.predicate = added
            }
        }
        return next
    }
}
