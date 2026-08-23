# hangar

A type-safe query layer for PostgreSQL, built directly on
[PostgresNIO](https://github.com/vapor/postgres-nio).

Models are structs. Queries are values you compose. Columns are keypaths, so a
typo is a compile error rather than a runtime one.

```swift
@Entity("posts")
struct Post {
    @ID var id: UUID
    @Column var title: String
    @Column var viewCount: Int
    @BelongsTo(\.authorID) var author: Loadable<Author>
}

let popular = try await repo.all(
    Post.where { $0.viewCount > 1_000 }
        .order { $0.viewCount.desc() }
        .limit(20)
        .preload(\.author)
)
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Swift-Flight/hangar", from: "0.1.0")
]
```

Requires Swift 6.2+. Linux and macOS 15+.

## Queries are values

Nothing executes until a `Repo` runs it, so a query can be built in pieces,
passed around, stored, and reused:

```swift
let base = Post.where { $0.published == true }

let recent = base.order { $0.createdAt.desc() }.limit(10)
let byAuthor = base.where { $0.authorID == id }      // `base` is unchanged
```

Composition never mutates what it was composed from.

## What it does

**Predicates** with real operators — `==`, `<`, `&&`, `||`, `!`, `in`,
`like`, `ilike`:

```swift
Post.where { $0.published == true && $0.viewCount > 100 }
Post.where { $0.title.ilike("%swift%") }
Post.where { $0.authorID.in(activeAuthorIDs) }
```

**Aggregates and projections** into any `Decodable`:

```swift
struct AuthorStats: Decodable {
    let authorID: UUID
    let posts: Int
    let views: Int
}

try await repo.all(
    Post.groupBy { $0.authorID }
        .having { $0.viewCount.sum() > 1_000 }
        .select(into: AuthorStats.self) { p in
            (p.authorID, p.id.count(), p.viewCount.sum())
        }
)
```

**Joins**, inner and left, with the base entity's columns qualified:

```swift
Post.leftJoin(Comment.self, on: { post, comment in comment.postID == post.id })
    .groupBy { post, _ in post.id }
```

**Preloading** that batches rather than N+1 — one query per association, using
`= ANY($1)`:

```swift
try await repo.all(Post.all.preload(\.author).preload(\.comments))
```

An association that was never preloaded throws `notPreloaded` rather than
silently returning nothing. Loud beats empty.

**Transactions** with real savepoint nesting:

```swift
try await repo.transaction { tx in
    try await tx.insert(order)
    try await tx.transaction { inner in       // SAVEPOINT
        try await inner.insert(lineItem)
    }
}
```

**Streaming** for result sets that should not be materialized:

```swift
try await repo.stream(Post.all.order { $0.id.asc() }) { posts in
    for try await post in posts { … }
}
```

**Changesets**, upserts, dynamic filters over an explicit allowlist, and
read-replica routing.

## Safety

Identifiers are always quoted with embedded quotes doubled. Values are always
bound, never interpolated. Dynamic filter fields resolve through an allowlist
and are never interpolated. Savepoint names are generated from an integer
depth, never from user input.

`SQLFragment`'s `\(raw:)` is the one deliberate hole, and it announces itself.

## Binding a repo to a connection you own

A `Repo` normally holds a pool. It can instead be pinned to a connection you
manage — which is how a framework binds one to a request scope:

```swift
let repo = Repo(connection: connection)
```

> **If that connection is already inside a transaction, say so.**
>
> ```swift
> Repo(connection: connection, inTransaction: true)
> ```
>
> At the default, the repo believes it is outermost and `transaction { }`
> emits a literal `BEGIN`/`COMMIT`. Postgres ignores the redundant `BEGIN`,
> and the `COMMIT` then ends *your* transaction — so work you meant to roll
> back becomes durable. With `inTransaction: true` it nests as a savepoint.
>
> Hangar cannot detect this itself: PostgresNIO does not expose the
> connection's transaction status. The caller knows, so the caller says.

## What is not here

No migrations — use a migration tool. No bulk `update(query, set:)` yet
(bulk `delete(query)` exists). No CTEs, no `DISTINCT ON`, no three-table
joins or self-joins, no `@HasMany(through:)`, no transaction isolation
levels, and no escape hatch for running arbitrary SQL *inside* a
`transaction { }`.

Those are real gaps rather than statements of principle. The ones most likely
to bite are bulk update and the in-transaction escape hatch.

## Documentation

```bash
HANGAR_BUILD_DOCS=1 swift package generate-documentation --target Hangar
```

## Benchmarks

See [BENCHMARKS.md](BENCHMARKS.md), including the measured cost of unnamed vs
named prepared statements and where preloading stops scaling.

## License

MIT. See [LICENSE](LICENSE).
