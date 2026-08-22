import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Entity("posts")` (design §4): generates `Columns`, table metadata, the
/// positional row decoder, a memberwise initializer, the per-column binding
/// switch, and the `Table` conformance.
///
/// Built fixtures-first per design §4.4: the assertMacroExpansion fixtures
/// in HangarMacroTests ARE the specification of this expansion; the design
/// doc's prose examples are illustrative.
public struct EntityMacro: MemberMacro, ExtensionMacro {

    // MARK: Members

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnoseError(
                "entity.notstruct",
                "@Entity can only be attached to a struct — models are values (design §3).",
                at: node)
            return []
        }
        guard let tableName = staticStringArgument(of: node) else {
            context.diagnoseError(
                "entity.tablename",
                "@Entity needs a static string literal table name: @Entity(\"posts\").",
                at: node)
            return []
        }
        guard let members = parseEntityMembers(of: structDecl, in: context) else {
            return []
        }
        let properties = members.compactMap { member -> EntityProperty? in
            if case .column(let property) = member { return property }
            return nil
        }
        let associations = members.compactMap { member -> EntityAssociation? in
            if case .association(let association) = member { return association }
            return nil
        }
        guard !properties.isEmpty else {
            context.diagnoseError(
                "entity.empty",
                "@Entity struct has no stored properties — a table needs at least one column.",
                at: node)
            return []
        }
        guard properties.contains(where: \.isPrimaryKey) else {
            context.diagnoseError(
                "entity.nokey",
                "@Entity needs a primary key — mark one or more properties with @ID.",
                at: node)
            return []
        }

        let access = structDecl.modifiers.contains { $0.name.tokenKind == .keyword(.public) }
            ? "public " : ""
        let typeName = structDecl.name.text

        var declarations: [DeclSyntax] = [
            columnsStruct(properties, tableName: tableName, access: access),
            "\(raw: access)static let queryColumns = Columns()",
            schemaDeclaration(properties, tableName: tableName, access: access),
            "\(raw: access)static let tableName = \(literal: tableName)",
            tableModelColumns(properties, typeName: typeName, access: access),
            memberwiseInit(members, access: access),
            rowDecoder(members, tableName: tableName, access: access),
            bindSwitch(properties, access: access),
            changesetBindSwitch(properties, access: access),
        ]
        if !associations.isEmpty {
            declarations.append(
                associationRegistry(
                    associations, properties: properties, typeName: typeName, access: access))
        }
        return declarations
    }

    // MARK: Conformance

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // An empty list means the conformances already exist somewhere;
        // otherwise it names exactly the ones still needed (Hangar.Table,
        // Changesets.TableModel).
        guard !protocols.isEmpty else { return [] }
        let list = protocols.map(\.trimmedDescription).joined(separator: ", ")
        return [try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: list) {}")]
    }

    // MARK: Generated pieces

    private static func columnsStruct(
        _ properties: [EntityProperty], tableName: String, access: String
    ) -> DeclSyntax {
        // The table rides along on every column so multi-table scopes
        // (correlated subqueries, joins) can render qualified references.
        let members = properties
            .map { #"    \#(access)let \#($0.identifier) = Hangar.Column<\#($0.typeText)>("\#($0.columnName)", table: "\#(tableName)")"# }
            .joined(separator: "\n")
        return """
            \(raw: access)struct Columns: Sendable {
            \(raw: members)
            }
            """
    }

    private static func schemaDeclaration(
        _ properties: [EntityProperty], tableName: String, access: String
    ) -> DeclSyntax {
        let definitions = properties
            .map {
                #"        Hangar.ColumnDefinition(name: "\#($0.columnName)", isPrimaryKey: \#($0.isPrimaryKey), isGenerated: \#($0.isGenerated)),"#
            }
            .joined(separator: "\n")
        return """
            \(raw: access)static let schema = Hangar.TableSchema(
                name: "\(raw: tableName)",
                columns: [
            \(raw: definitions)
                ]
            )
            """
    }

    /// The `Changesets.TableModel` catalog (design §11.2): the keypath →
    /// column-name mapping changesets erase through. Names are identical to
    /// the schema's by construction, so `ValidatedChanges` keys always match
    /// what the renderer expects.
    private static func tableModelColumns(
        _ properties: [EntityProperty], typeName: String, access: String
    ) -> DeclSyntax {
        let entries = properties
            .map { property in
                var arguments = #""\#(property.columnName)", \\#(typeName).\#(property.identifier)"#
                if property.isPrimaryKey {
                    arguments += ", primaryKey: true"
                }
                return "    Changesets.TableColumn(\(arguments)),"
            }
            .joined(separator: "\n")
        return """
            \(raw: access)static let columns: [Changesets.TableColumn<\(raw: typeName)>] = [
            \(raw: entries)
            ]
            """
    }

    private static func memberwiseInit(_ members: [ParsedMember], access: String) -> DeclSyntax {
        // The compiler stops synthesizing the memberwise init once the macro
        // adds init(from:), so the macro restores it. Associations default
        // to .notLoaded so constructing a model never requires naming them.
        let parameters = members
            .map { member in
                switch member {
                case .column(let property):
                    var parameter = "\(property.identifier): \(property.typeText)"
                    if let defaultValue = property.defaultValueText {
                        parameter += " = \(defaultValue)"
                    } else if property.isOptional {
                        parameter += " = nil"
                    }
                    return parameter
                case .association(let association):
                    return "\(association.identifier): \(association.typeText) = .notLoaded(association: \"\(association.identifier)\")"
                }
            }
            .joined(separator: ", ")
        let assignments = members
            .map { "    self.\($0.identifier) = \($0.identifier)" }
            .joined(separator: "\n")
        return """
            \(raw: access)init(\(raw: parameters)) {
            \(raw: assignments)
            }
            """
    }

    private static func rowDecoder(
        _ members: [ParsedMember], tableName: String, access: String
    ) -> DeclSyntax {
        var cellIndex = 0
        var lines: [String] = []
        for member in members {
            switch member {
            case .column(let property):
                let decode: String
                if property.isJSONB {
                    let function = property.isOptional ? "_decodeOptionalJSONB" : "_decodeJSONB"
                    decode = #"Hangar.\#(function)(\#(property.wrappedTypeText).self, from: cells[\#(cellIndex)], table: "\#(tableName)", column: "\#(property.columnName)")"#
                } else {
                    decode = #"Hangar._decodeColumn(\#(property.typeText).self, from: cells[\#(cellIndex)], table: "\#(tableName)", column: "\#(property.columnName)")"#
                }
                lines.append("    self.\(property.identifier) = try \(decode)")
                cellIndex += 1
            case .association(let association):
                // Not a column (§4.3): never decoded, populated only by
                // preload.
                lines.append("    self.\(association.identifier) = .notLoaded(association: \"\(association.identifier)\")")
            }
        }
        return """
            \(raw: access)init(from row: PostgresRow) throws {
                let cells = row.makeRandomAccess()
                try Hangar._checkColumnCount(cells.count, expected: \(raw: cellIndex), table: "\(raw: tableName)")
            \(raw: lines.joined(separator: "\n"))
            }
            """
    }

    /// The association registry (design §4, item 4): keypath → loader, with
    /// every key type captured statically at expansion. `parentKey` for
    /// has-many/has-one is this entity's first `@ID` property; `references`
    /// for belongs-to defaults to the related type's `id` (Ecto's
    /// convention), overridable via `references:`.
    private static func associationRegistry(
        _ associations: [EntityAssociation],
        properties: [EntityProperty],
        typeName: String,
        access: String
    ) -> DeclSyntax {
        // Guarded by the primary-key diagnostic before generation.
        let primaryKey = properties.first(where: \.isPrimaryKey)!.identifier
        let entries = associations
            .map { association in
                let target = "\\\(typeName).\(association.identifier)"
                let loader: String
                switch association.kind {
                case .hasMany:
                    loader = "Hangar._hasMany(name: \"\(association.identifier)\", parentKey: \\\(typeName).\(primaryKey), foreignKey: \(association.foreignKeyText), target: \(target))"
                case .hasOne:
                    loader = "Hangar._hasOne(name: \"\(association.identifier)\", parentKey: \\\(typeName).\(primaryKey), foreignKey: \(association.foreignKeyText), target: \(target))"
                case .belongsTo:
                    let references = association.referencesText ?? "\\\(association.relatedTypeText).id"
                    loader = "Hangar._belongsTo(name: \"\(association.identifier)\", foreignKey: \(association.foreignKeyText), references: \(references), target: \(target))"
                }
                return "    if keyPath == \(target) {\n        return \(loader)\n    }"
            }
            .joined(separator: "\n")
        return """
            \(raw: access)static func _association(for keyPath: AnyKeyPath) -> (any Sendable)? {
            \(raw: entries)
                return nil
            }
            """
    }

    /// The changeset-value bind switch: `ValidatedChanges` carries values as
    /// `any Sendable`; each case casts back to the column's static type
    /// (through the optional when the column is nullable — a boxed
    /// `Optional.none` means "set NULL"). A failed cast returns nil and the
    /// `Repo` raises `HangarError.changesetValueMismatch`.
    private static func changesetBindSwitch(
        _ properties: [EntityProperty], access: String
    ) -> DeclSyntax {
        let cases = properties
            .map { property in
                let castType = property.isOptional
                    ? "\(property.wrappedTypeText)?" : property.typeText
                let bind = property.isJSONB
                    ? "Hangar.SQLBind(jsonb: $0)"
                    : "Hangar.SQLBind($0)"
                return "    case \"\(property.columnName)\":\n        return (value as? \(castType)).map { \(bind) }"
            }
            .joined(separator: "\n")
        return """
            \(raw: access)static func _changesetBind(column: String, value: any Sendable) -> Hangar.SQLBind? {
                switch column {
            \(raw: cases)
                default:
                    return nil
                }
            }
            """
    }

    private static func bindSwitch(_ properties: [EntityProperty], access: String) -> DeclSyntax {
        let cases = properties
            .map { property in
                let bind = property.isJSONB
                    ? "Hangar.SQLBind(jsonb: self.\(property.identifier))"
                    : "Hangar.SQLBind(self.\(property.identifier))"
                return "    case \"\(property.columnName)\":\n        return \(bind)"
            }
            .joined(separator: "\n")
        return """
            \(raw: access)func _bind(for column: String) -> Hangar.SQLBind? {
                switch column {
            \(raw: cases)
                default:
                    return nil
                }
            }
            """
    }
}
