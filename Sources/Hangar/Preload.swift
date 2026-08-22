import Changesets
import PostgresNIO

// Preloading (design §7): always batched, never joined. For N parents,
// each association costs exactly one extra query — `WHERE fk = ANY($1)` —
// then rows are grouped in memory and assigned into each parent's
// `Loadable`. Two has-many preloads never multiply into a cartesian
// product, which is why separate queries are the default (§7.2).
//
// The underscored loader types and factories are referenced by
// `@Entity`-generated `_association(for:)` implementations — public for
// that reason only, not user API. Each factory captures the association's
// key type inside closures, so the registry can stay untyped over keys
// while parents/children remain fully typed.

/// A key type usable for batching: bindable alone and as an array, and
/// hashable for in-memory grouping.
public typealias PreloadKey = ColumnCodable & Hashable & PostgresArrayEncodable

// MARK: - Loaders (one per association shape)

public struct _HasManyLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run: @Sendable (
        _ parents: inout [Parent],
        _ repo: Repo,
        _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
    ) async throws -> Void
}

/// `@BelongsTo` with a non-optional foreign key: every parent must find its
/// row; a dangling reference throws rather than lying with `.notLoaded`.
public struct _ToOneLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run: @Sendable (
        _ parents: inout [Parent],
        _ repo: Repo,
        _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
    ) async throws -> Void
}

/// `@HasOne`, or `@BelongsTo` over an optional foreign key: absence is
/// data, expressed as `.loaded(nil)` — distinct from `.notLoaded` (§7.3).
public struct _OptionalToOneLoader<Parent: Table, Child: Table>: Sendable {
    let name: String
    let run: @Sendable (
        _ parents: inout [Parent],
        _ repo: Repo,
        _ tune: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child>
    ) async throws -> Void
}

// MARK: - Factories (called from @Entity-generated metadata)

public func _hasMany<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    parentKey: KeyPath<Parent, Key> & Sendable,
    foreignKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<[Child]>> & Sendable
) -> _HasManyLoader<Parent, Child> {
    _HasManyLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: parentKey] }))
        let children = try await repo.all(
            filtered(tune(Child.all), by: foreignKey, in: keys, association: name))
        let grouped = Dictionary(grouping: children) { $0[keyPath: foreignKey] }
        for index in parents.indices {
            let key = parents[index][keyPath: parentKey]
            parents[index][keyPath: target] = .loaded(grouped[key] ?? [])
        }
    }
}

public func _belongsTo<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    foreignKey: KeyPath<Parent, Key> & Sendable,
    references relatedKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<Child>> & Sendable
) -> _ToOneLoader<Parent, Child> {
    _ToOneLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: foreignKey] }))
        let related = try await repo.all(
            filtered(tune(Child.all), by: relatedKey, in: keys, association: name))
        // First row per key wins. NOT `Dictionary(uniqueKeysWithValues:)`:
        // that traps on a duplicate, and a `references:` pointed at a
        // non-unique column is a user mistake, not a Hangar invariant —
        // §7.3 says fail the request, never the node.
        let indexed = Dictionary(related.map { ($0[keyPath: relatedKey], $0) }) { first, _ in first }
        for index in parents.indices {
            guard let child = indexed[parents[index][keyPath: foreignKey]] else {
                throw HangarError.danglingBelongsTo(table: Parent.schema.name, association: name)
            }
            parents[index][keyPath: target] = .loaded(child)
        }
    }
}

/// `@BelongsTo` over a nullable foreign key: parents with a nil key load
/// `.loaded(nil)` without ever querying for them.
public func _belongsTo<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    foreignKey: KeyPath<Parent, Key?> & Sendable,
    references relatedKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<Child?>> & Sendable
) -> _OptionalToOneLoader<Parent, Child> {
    _OptionalToOneLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.compactMap { $0[keyPath: foreignKey] }))
        let related = keys.isEmpty
            ? []
            : try await repo.all(
                filtered(tune(Child.all), by: relatedKey, in: keys, association: name))
        // First row per key wins — see the non-optional overload above.
        let indexed = Dictionary(related.map { ($0[keyPath: relatedKey], $0) }) { first, _ in first }
        for index in parents.indices {
            guard let key = parents[index][keyPath: foreignKey] else {
                parents[index][keyPath: target] = .loaded(nil)
                continue
            }
            guard let child = indexed[key] else {
                throw HangarError.danglingBelongsTo(table: Parent.schema.name, association: name)
            }
            parents[index][keyPath: target] = .loaded(child)
        }
    }
}

public func _hasOne<Parent: Table, Child: Table, Key: PreloadKey>(
    name: String,
    parentKey: KeyPath<Parent, Key> & Sendable,
    foreignKey: KeyPath<Child, Key> & Sendable,
    target: WritableKeyPath<Parent, Loadable<Child?>> & Sendable
) -> _OptionalToOneLoader<Parent, Child> {
    _OptionalToOneLoader(name: name) { parents, repo, tune in
        guard !parents.isEmpty else { return }
        let keys = Array(Set(parents.map { $0[keyPath: parentKey] }))
        let children = try await repo.all(
            filtered(tune(Child.all), by: foreignKey, in: keys, association: name))
        // First row per key wins; a schema that allows several is a
        // has-many wearing the wrong attribute.
        var indexed: [Key: Child] = [:]
        for child in children where indexed[child[keyPath: foreignKey]] == nil {
            indexed[child[keyPath: foreignKey]] = child
        }
        for index in parents.indices {
            parents[index][keyPath: target] = .loaded(indexed[parents[index][keyPath: parentKey]])
        }
    }
}

/// ANDs `column = ANY($keys)` onto the (possibly user-tuned) child query.
/// The column name resolves at runtime through the child's TableModel
/// metadata — the one piece of cross-type information the macro cannot see
/// at expansion time.
private func filtered<Child: Table, Key: PreloadKey>(
    _ query: Query<Child, Child>,
    by keyPath: KeyPath<Child, Key> & Sendable,
    in keys: [Key],
    association: String
) throws -> Query<Child, Child> {
    guard let column = Child.columnName(for: keyPath) else {
        throw HangarError.unknownAssociation(table: Child.schema.name, association: association)
    }
    let membership = SQLExpression.anyOf(
        .column(table: Child.schema.name, name: column),
        .bind(SQLBind { try $0.append(keys) }))
    var next = query
    if let existing = next.predicate {
        next.predicate = Predicate(expression: .infix("AND", existing.expression, membership))
    } else {
        next.predicate = Predicate(expression: membership)
    }
    return next
}

// MARK: - Query surface (design §3.2 / §7.2)

/// One pending preload on a query — everything about the association is
/// captured typed at the `.preload` call site; execution happens in
/// `Repo.all` after the parent rows decode.
struct PreloadStep<Model: Table>: Sendable {
    let run: @Sendable (inout [Model], Repo) async throws -> Void
}

extension Query {
    /// Preloads a `@HasMany` association, optionally tuning the child query
    /// (ordering, filtering, its own nested `.preload`s — §7.2):
    ///
    /// ```swift
    /// Post.where { $0.published }
    ///     .preload(\.comments) { $0.order { $0.createdAt.asc() }.preload(\.author) }
    /// ```
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<[Child]>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> Query<Model, Result> {
        appendingPreload(association) { (loader: _HasManyLoader<Model, Child>, parents, repo) in
            try await loader.run(&parents, repo, nested)
        }
    }

    /// Preloads a `@BelongsTo` association with a non-optional foreign key.
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<Child>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> Query<Model, Result> {
        appendingPreload(association) { (loader: _ToOneLoader<Model, Child>, parents, repo) in
            try await loader.run(&parents, repo, nested)
        }
    }

    /// Preloads a `@HasOne`, or a `@BelongsTo` over a nullable foreign key.
    public func preload<Child: Table>(
        _ association: WritableKeyPath<Model, Loadable<Child?>> & Sendable,
        _ nested: @escaping @Sendable (Query<Child, Child>) -> Query<Child, Child> = { $0 }
    ) -> Query<Model, Result> {
        appendingPreload(association) { (loader: _OptionalToOneLoader<Model, Child>, parents, repo) in
            try await loader.run(&parents, repo, nested)
        }
    }

    private func appendingPreload<Loader>(
        _ association: AnyKeyPath & Sendable,
        _ execute: @escaping @Sendable (Loader, inout [Model], Repo) async throws -> Void
    ) -> Query<Model, Result> {
        var next = self
        next.preloads.append(
            PreloadStep { parents, repo in
                guard let loader = Model._association(for: association) as? Loader else {
                    throw HangarError.unknownAssociation(
                        table: Model.schema.name, association: "\(association)")
                }
                try await execute(loader, &parents, repo)
            })
        return next
    }
}
