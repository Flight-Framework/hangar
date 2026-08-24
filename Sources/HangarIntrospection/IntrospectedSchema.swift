import Foundation

/// A column as the database describes it.
public struct IntrospectedColumn: Sendable, Equatable {
    public let name: String
    /// Postgres's own name for the type — `int4`, `text`, `_text` for an
    /// array of text, or the enum's type name.
    public let udtName: String
    public let isNullable: Bool
    public let isPrimaryKey: Bool
    /// Whether the database supplies a value when one is not given — a
    /// `DEFAULT`, a sequence, or an identity column. Such columns are
    /// excluded from INSERTs and read back, which is what `@ID(generated:)`
    /// expresses.
    public let hasDefault: Bool
    public let isIdentity: Bool
    /// The enum's labels, when this column's type is a Postgres enum.
    public let enumLabels: [String]

    public init(
        name: String, udtName: String, isNullable: Bool, isPrimaryKey: Bool,
        hasDefault: Bool, isIdentity: Bool, enumLabels: [String] = []
    ) {
        self.name = name
        self.udtName = udtName
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.hasDefault = hasDefault
        self.isIdentity = isIdentity
        self.enumLabels = enumLabels
    }

    public var isArray: Bool { udtName.hasPrefix("_") }
    public var isEnum: Bool { !enumLabels.isEmpty }
}

/// A foreign key, which is what an association is generated from.
public struct IntrospectedForeignKey: Sendable, Equatable {
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String

    public init(column: String, referencedTable: String, referencedColumn: String) {
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
    }
}

/// One table, as read from the catalogue.
public struct IntrospectedTable: Sendable, Equatable {
    public let name: String
    public let schema: String
    public let columns: [IntrospectedColumn]
    public let foreignKeys: [IntrospectedForeignKey]

    public init(
        name: String, schema: String = "public",
        columns: [IntrospectedColumn], foreignKeys: [IntrospectedForeignKey] = []
    ) {
        self.name = name
        self.schema = schema
        self.columns = columns
        self.foreignKeys = foreignKeys
    }
}
