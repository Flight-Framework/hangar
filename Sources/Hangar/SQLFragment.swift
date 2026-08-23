import PostgresNIO

/// The raw-SQL escape hatch, safe by construction: in
///
/// ```swift
/// Post.where { p in
///     p.published && SQLFragment("char_length(\(p.title)) > \(minLength)")
/// }
/// ```
///
/// the **literal** parts of the string become SQL, and every interpolated
/// value becomes a bound `$n` parameter — a Swift value cannot become SQL
/// text through interpolation, the same guarantee Ecto's `fragment/1`
/// makes. Interpolating a `Column` renders its (quoted) identifier, which
/// is how fragments reference real columns without strings.
///
/// For the rare case that genuinely needs computed SQL text there is
/// `\(raw:)`, which is exactly as dangerous as it sounds: the string goes
/// into the statement verbatim. Never pass it anything derived from user
/// input.
public struct SQLFragment: Sendable, ExpressibleByStringInterpolation {
    enum Part: Sendable {
        case sql(String)
        case bind(SQLBind)
    }

    let parts: [Part]

    public init(stringLiteral value: String) {
        self.parts = [.sql(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        self.parts = stringInterpolation.parts
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var parts: [Part] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            parts.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            parts.append(.sql(literal))
        }

        /// A value — always a bound parameter.
        public mutating func appendInterpolation<V: ColumnCodable>(_ value: V) {
            parts.append(.bind(SQLBind(value)))
        }

        /// An optional value — a bound parameter or NULL.
        public mutating func appendInterpolation<V: ColumnCodable>(_ value: V?) {
            parts.append(.bind(SQLBind(value)))
        }

        /// A column — its quoted identifier, never a bind.
        public mutating func appendInterpolation<V>(_ column: Column<V>) {
            parts.append(.sql(SQLRenderer.quote(column.name)))
        }

        /// Verbatim SQL text. The deliberate hole in the safety story, and
        /// it announces itself at every call site. Never user input.
        public mutating func appendInterpolation(raw: String) {
            parts.append(.sql(raw))
        }
    }
}

extension SQLFragment: PredicateConvertible {
    /// The fragment as a boolean predicate, composable with `&&`/`||`/`!`
    /// like any other.
    public var predicate: Predicate {
        Predicate(expression: .fragment(parts))
    }
}

extension SQLFragment {
    /// The fragment as a typed SELECT-list expression:
    ///
    /// ```swift
    /// Post.select { p in SQLFragment("char_length(\(p.body))").expression(as: Int.self) }
    /// ```
    public func expression<V>(as type: V.Type) -> SelectExpression<V> {
        SelectExpression(expression: .fragment(parts))
    }
}
