/// `@Entity("posts")` — the macro that makes a struct a Hangar table
/// (design §4). Generates:
///
/// 1. `Columns` — one typed `Column<T>` per stored property, for the
///    closure-based operators.
/// 2. A positional row decoder, `init(from: PostgresRow)` — compile-time
///    generated, no reflection, no string-keyed lookup per field.
/// 3. Table metadata (`schema`) — name, columns, primary key, insertable
///    vs. generated.
/// 4. A memberwise initializer (macro-generated because the compiler stops
///    synthesizing one once the macro adds `init(from:)`).
///
/// Association metadata (`@HasMany` et al.) arrives in Phase 3.
///
/// Table name is explicit — no pluralization inference, because inference
/// is wrong often enough that guessing costs more than typing (§4.1).
///
/// Also generates the `Changesets.TableModel` conformance (design §11.2):
/// `tableName`, the `columns` keypath catalog, and the erased-value bind
/// switch — so `Changeset(Post.self)` and `repo.insert(changeset)` work
/// with no extra declarations.
@attached(
    member,
    names: named(Columns), named(queryColumns), named(schema), named(tableName),
        named(columns), named(init), named(_bind(for:)),
        named(_changesetBind(column:value:)), named(_association(for:)))
@attached(extension, conformances: Table, TableModel)
public macro Entity(_ tableName: String) =
    #externalMacro(module: "HangarMacrosImpl", type: "EntityMacro")

/// Marks the primary key (composite keys: multiple `@ID` properties).
/// `generated: true` means the database produces the value (identity /
/// serial / default) — the column is excluded from INSERT lists and read
/// back via RETURNING.
@attached(peer)
public macro ID(generated: Bool = false) =
    #externalMacro(module: "HangarMacrosImpl", type: "IDMacro")

/// Overrides the default camelCase → snake_case column naming (§4.1):
/// `@Column("created_at") var createdAt: Date`.
@attached(peer)
public macro Column(_ name: String) =
    #externalMacro(module: "HangarMacrosImpl", type: "ColumnNameMacro")

/// Stores any `Codable` property as a `jsonb` column (§4.2).
@attached(peer)
public macro JSONB() =
    #externalMacro(module: "HangarMacrosImpl", type: "JSONBMacro")

/// A one-to-many association (design §7.1): `foreignKey` is the child
/// column that references this table (the parent's primary key by
/// default). The property must be `var name: Loadable<[Child]>` — not a
/// column; populated only by `.preload` (§4.3).
///
/// ```swift
/// @HasMany(foreignKey: \Comment.postID) var comments: Loadable<[Comment]>
/// ```
@attached(peer)
public macro HasMany(foreignKey: AnyKeyPath) =
    #externalMacro(module: "HangarMacrosImpl", type: "HasManyMacro")

/// A child-side association (§7.1): `foreignKey` is *this* table's column
/// referencing the related row; `references` is the related column it
/// points at (the related type's `id` by default, Ecto's convention). A
/// non-optional foreign key pairs with `Loadable<Related>`; a nullable one
/// with `Loadable<Related?>` (`.loaded(nil)` = no reference).
@attached(peer)
public macro BelongsTo(foreignKey: AnyKeyPath, references: AnyKeyPath? = nil) =
    #externalMacro(module: "HangarMacrosImpl", type: "BelongsToMacro")

/// A one-to-zero-or-one association (§7.1): like `@HasMany` but the
/// property is `Loadable<Related?>` — absence is data (`.loaded(nil)`),
/// distinct from not-preloaded (§7.3).
@attached(peer)
public macro HasOne(foreignKey: AnyKeyPath) =
    #externalMacro(module: "HangarMacrosImpl", type: "HasOneMacro")
