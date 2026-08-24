import Foundation

/// Maps Postgres types to Swift ones.
///
/// The mapping is deliberately conservative: where a Postgres type has no
/// faithful Swift counterpart the generator says so in a comment rather than
/// guessing, because a wrong type here is a decode failure at runtime in code
/// someone did not write by hand and will not think to doubt.
public enum TypeMapping {

    /// The Swift type for a column, or nil when there is no safe answer.
    public static func swiftType(for column: IntrospectedColumn) -> String? {
        if column.isEnum {
            return enumTypeName(for: column.udtName)
        }
        if column.isArray {
            // Postgres names an array type by prefixing its element's name.
            let element = IntrospectedColumn(
                name: column.name, udtName: String(column.udtName.dropFirst()),
                isNullable: false, isPrimaryKey: false, hasDefault: false, isIdentity: false)
            guard let inner = swiftType(for: element) else { return nil }
            // Only the element types PostgresNIO can encode and decode as
            // arrays. Decimal and Data have neither conformance, so a
            // numeric[] or bytea[] column is left for a human.
            let arrayable: Set<String> = [
                "Bool", "Int16", "Int32", "Int", "Int64", "Float", "Double", "String", "UUID",
                "Date",
            ]
            return arrayable.contains(inner) ? "[\(inner)]" : nil
        }
        return scalars[column.udtName]
    }

    private static let scalars: [String: String] = [
        "bool": "Bool",
        "int2": "Int16",
        "int4": "Int32",
        "int8": "Int",
        "float4": "Float",
        "float8": "Double",
        "numeric": "Decimal",
        "text": "String",
        "varchar": "String",
        "bpchar": "String",
        "name": "String",
        "uuid": "UUID",
        "date": "Date",
        "timestamp": "Date",
        "timestamptz": "Date",
        "bytea": "Data",
        "json": "String",
        "jsonb": "String",
    ]

    /// `jsonb` maps to `String` above so a column is never dropped, but the
    /// generator flags it: the point of `@JSONB` is a real Codable type, and
    /// only the author knows its shape.
    public static func needsJSONBAttention(_ column: IntrospectedColumn) -> Bool {
        column.udtName == "jsonb" || column.udtName == "json"
    }

    /// `post_status` → `PostStatus`.
    public static func enumTypeName(for udtName: String) -> String {
        pascalCase(udtName)
    }

    /// `created_at` → `createdAt`. Leaves an already-camelCase name alone,
    /// which matters because not every schema is snake_case.
    public static func camelCase(_ identifier: String) -> String {
        guard identifier.contains("_") else { return identifier }
        let parts = identifier.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return identifier }
        return ([String(first)] + parts.dropFirst().map { $0.capitalizedFirst }).joined()
    }

    /// `blog_posts` → `BlogPost`. Singularisation is the crude kind on
    /// purpose: it handles the common cases and a wrong guess is one word for
    /// a human to fix, whereas a real inflector is a dependency and a source
    /// of surprises.
    public static func typeName(forTable table: String) -> String {
        pascalCase(singular(table))
    }

    static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ses") || word.hasSuffix("xes") || word.hasSuffix("zes")
            || word.hasSuffix("ches") || word.hasSuffix("shes")
        {
            return String(word.dropLast(2))
        }
        // "status", "analysis", "address" are not plurals. Latin and Greek
        // endings are where a naive trailing-s rule does the most damage,
        // because the result is a word that looks almost right.
        for ending in ["ss", "us", "is", "os"] where word.hasSuffix(ending) { return word }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    static func pascalCase(_ identifier: String) -> String {
        identifier.split(separator: "_", omittingEmptySubsequences: true)
            .map { $0.capitalizedFirst }
            .joined()
    }
}

extension StringProtocol {
    fileprivate var capitalizedFirst: String {
        guard let first else { return String(self) }
        return first.uppercased() + dropFirst()
    }
}
