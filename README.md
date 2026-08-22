# Hangar

An Ecto-inspired query layer for Postgres, built directly on PostgresNIO.
The design specification lives at [`../hangar-design.md`](../hangar-design.md);
this README records build status and decisions made during implementation.

## Build status

| Phase (design §12) | Status |
|---|---|
| Pre-Phase-1 spikes: `&&`/`||` overloads (§3.1), vertical slice | ✅ Done — see verdicts below |
| **Phase 1 — Foundation**: `@Entity`, `Columns`, row decoders, Query AST, renderer, `Repo` CRUD | ✅ Done |
| **Phase 2 — Transactions and Multi**: `repo.transaction`, savepoint nesting, `Multi` with typed keys, changeset integration | ✅ Done |
| **Phase 3 — Associations and preload**: `@HasMany`/`@BelongsTo`/`@HasOne`, `Loadable<T>`, batched preload, nested preloads | ✅ Done (join strategy and `through:` deferred, see below) |
| **Phase 4 — Projections, aggregates, subqueries**: pack-based `select`, `select(into:)`, aggregates, `groupBy`/`having`, joins, `IN`/correlated `EXISTS`, upsert, `distinct` | ✅ Done (CTEs/derived tables deferred, see below) |
| **Performance pass**: benchmark harness, ~10× faster rendering, `repo.stream`, preload trap fix | ✅ Done — see [BENCHMARKS.md](BENCHMARKS.md) |
| **Phase 5 — Dynamic queries and polish**: allowlisted dynamic filters, read replicas, query logging/metrics, safe SQL fragments | ✅ Done |

**All five §12 phases are complete, and the §11 Flight adapter is built**:
flight-data-postgres registers a request-scoped `Repo` bound to the scope's
connection — Hangar queries participate in `@Transactional` transactions —
and the Demo app runs on Hangar end to end; StructuredQueries has left the
Flight stack, as the design's header promised. The remaining backlog is the
deferred list below plus the prepared-statement gap in BENCHMARKS.md.

Verified on Swift 6.2.3 / Linux against Postgres 16, PostgresNIO 1.33.

### Spike verdicts (§12 "spike before Phase 1")

- **`&&`/`||` overloading (§3.1): resolves cleanly.** Overloads over
  `PredicateConvertible` never compete with the standard library's
  `Bool`-only operators, in either direction. The fallback
  (`.and()`/`.or()` chaining) is not needed. Pinned by
  `Tests/HangarTests/PredicateSpikeTests.swift`.
- **Vertical slice: the macro → AST → renderer → PostgresNIO → decoder path
  works end-to-end**, including the dialect accommodations inherited from
  the flight-data-postgres spike (enum and jsonb parameters sent as
  `unknown`-OID text; jsonb version-byte stripping on decode). Pinned by
  `Tests/HangarTests/IntegrationTests.swift`.
- **Parameter packs (§6.3): workable — the fallback is not needed.** One
  pack-based signature covers `select` at every arity, including arity 1
  (`select { $0.id }` → `[UUID]`), with pack iteration for the SELECT list
  and a pack-expanded positional decode. The hand-written arity-1–6
  overloads the design held in reserve were never required. Pinned by
  `Tests/HangarTests/ProjectionTests.swift`.

## What Phase 1 ships

```swift
@Entity("posts")
struct Post: Sendable {
    @ID let id: UUID
    var title: String
    var published: Bool
    var viewCount: Int
    @Column("created_at") var createdAt: Date
    var nickname: String?              // nullable column
    var status: Status                 // enum Status: String, PostgresEnum
    @JSONB var metadata: PostMetadata  // any Codable → jsonb
}

let repo = Repo(client: postgresClient)

let posts = try await repo.all(
    Post.where { $0.published && $0.viewCount > 100 }
        .order { $0.createdAt.desc() }
        .limit(20))

try await repo.insert(post)     // INSERT ... RETURNING (generated keys come back)
try await repo.update(post)     // whole-row UPDATE by primary key
try await repo.delete(post)     // throws HangarError.staleModel if already gone
try await repo.one(query)       // nil, the row, or throws on >1 match
try await repo.count(query)
try await repo.exists(query)

// Ambient access (§5.1) — Hangar owns the task-local:
try await Repo.with(repo) {
    try await Repo.require().count(Post.all)
}
```

`@Entity` generates the `Columns` struct, a positional row decoder (no
reflection, no per-field string lookup), table metadata, a memberwise
initializer, and the per-column bind switch. `@ID(generated: true)` marks
database-generated keys (identity/serial): excluded from INSERT lists, read
back via RETURNING. Composite keys: multiple `@ID` properties.

The macro fixtures in `Tests/HangarMacroTests/EntityMacroFixtureTests.swift`
**are the specification** of the expansion (design §4.4); the design doc's
prose examples are illustrative.

## What Phase 2 ships

```swift
// Transactions (§5.2): throwing rolls back, returning commits, nesting
// becomes savepoints. Reads inside see the transaction's writes.
try await repo.transaction { tx in
    let user = try await tx.insert(userChangeset)
    try await tx.insert(profileChangeset(for: user))
    return user
}
throw RollbackError.intentional(value)   // rollback without a failure; rethrown to the caller

// Changesets (§11.2) — via the extracted swift-changeset package. Writes
// are minimal: only dirty fields hit the wire.
let changeset = Changeset(original: post)
    .change(\.title, input.title)
    .validate(\.title, .length(1...200))
try await repo.update(changeset)     // UPDATE ... SET "title" = $1 WHERE "id" = $2

// Multi (§10): typed keys, dependent steps, one transaction.
enum K {
    static let user = MultiKey<User>("user")
    static let profile = MultiKey<Profile>("profile")
}
let multi = Multi()
    .insert(K.user, userChangeset)
    .insert(K.profile) { r in profileChangeset(for: r[K.user]) }
    .run { r in try await sendWelcomeEmail(to: r[K.user]) }
switch try await repo.run(multi) {
case .success(let results): _ = results[K.user]          // typed, no cast
case .failure(let failure): _ = (failure.key, failure.error, failure.completed)
}
```

Every `@Entity` type also conforms to `Changesets.TableModel` (generated
keypath→column catalog), so `Changeset(Post.self)` works with no extra
declarations. A `let` property yields a read-only keypath, so a changeset
*cannot* `.change` it — primary keys declared `let` are structurally
unwritable through the changeset path.

## What Phase 3 ships

```swift
@Entity("posts")
struct Post: Sendable {
    @ID let id: UUID
    var title: String
    let authorID: UUID

    @HasMany(foreignKey: \Comment.postID)    var comments: Loadable<[Comment]>
    @BelongsTo(foreignKey: \Post.authorID)   var author: Loadable<Author>
}

// Batched, never joined (§7.2): one extra query per association —
// `WHERE fk = ANY($1)` — grouped in memory. Nested preloads compose, and
// the nested closure tunes the child query (ordering, filters, more
// preloads):
let posts = try await repo.all(
    Post.where { $0.published }
        .preload(\.author)
        .preload(\.comments) { $0.order { $0.createdAt.asc() }.preload(\.author) })

// Loaded/unloaded is a loud runtime distinction (§7.3): never a silent
// query, never a conflated nil.
let comments = try post.comments.get()   // throws .notPreloaded(association: "comments") if absent
```

Semantics worth knowing:
- **"No children" is data**: an empty has-many preloads as `.loaded([])`;
  a `@HasOne` with no row is `.loaded(nil)` (the property type is
  `Loadable<Related?>` — enforced by a diagnostic).
- **`@BelongsTo` over a nullable FK** pairs with `Loadable<Related?>`;
  nil keys load `.loaded(nil)` without querying. A *non-nil* key whose row
  is missing throws `HangarError.danglingBelongsTo` — the preload never
  lies with `.notLoaded`.
- **`references:` defaults to the related type's `id`** (Ecto's
  convention), overridable: `@BelongsTo(foreignKey: \A.bID, references: \B.key)`.
- Deferred: the explicit join strategy for belongs-to/has-one (§7.2)
  lands with Phase 4's join support; `@HasMany(through:)` after that.
  Association keys are single-column; composite-key associations are out
  of scope for now.

## What Phase 4 ships

```swift
// Projections (§6): select changes Result. One parameter-pack signature
// covers every arity (§6.3 spike verdict above).
let ids:   [UUID]           = try await repo.all(Post.select { $0.id })
let pairs: [(UUID, String)] = try await repo.all(Post.select { ($0.id, $0.title) })

// Aggregates + groupBy/having (§6.1). Dialect casts keep NUMERIC away
// from the decoder: integer sum() → Int? via ::bigint, avg() → Double?
// via ::float8; aggregates over zero rows are NULL, hence the optionals.
let totals = try await repo.all(
    Post.groupBy { $0.authorID }
        .having { $0.viewCount.sum() > 100 }
        .select { ($0.authorID, $0.id.count(), $0.viewCount.sum()) })

// Named projections (§6): labeled tuple → SQL aliases → Decodable keys.
struct PostSummary: Decodable { let id: UUID; let title: String; let commentCount: Int }
let summaries = try await repo.all(
    Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
        .groupBy { p, _ in p.id }.groupBy { p, _ in p.title }
        .select(into: PostSummary.self) { p, c in
            (id: p.id, title: p.title, commentCount: c.id.count())
        })

// Joins (§3.2): without a select, a join returns the *base* entity's rows
// (Ecto's semantics) — pairs come from explicit projections. Columns
// render table-qualified only in multi-table scopes.
let commented = try await repo.all(
    Post.join(Comment.self, on: { p, c in c.postID == p.id }).distinct())

// Subqueries (§8): IN and correlated EXISTS; inner binds share the outer
// statement's placeholder numbering.
let active = Author.where { $0.name != "" }.select { $0.id }
try await repo.all(Post.where { $0.authorID.in(active) })
try await repo.all(Post.where { p in Comment.where { $0.postID == p.id }.exists() })

// Upsert (§6.2): keypath-named conflict targets, EXCLUDED assignments.
try await repo.insert(changeset, onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
try await repo.insert(changeset, onConflict: .doNothing)   // nil on conflict
```

Deferred from Phase 4, recorded here deliberately:
- **CTEs and derived tables** (§8 `.with(name:query:)`, `Query.from(...)`):
  both need a "table literal" abstraction — a typed row source that isn't
  an `@Entity` — which deserves its own design pass rather than a bolt-on.
- **`distinctOn`** (§3.2) — with the ordering rules it implies.
- **Self-joins** — need table aliasing; refused with a clear error today.
- **The §7.2 join-strategy preload** — needs offset-capable row decoding;
  batched preloading covers the semantics meanwhile.

## What Phase 5 ships

```swift
// Allowlisted dynamic filters (§9.1) — untrusted field names resolve
// through the allowlist or the request is rejected; values are always
// bound. [String: DynamicFilterValue] decodes straight from a JSON body.
extension Post: DynamicallyFilterable {
    static let filterable: [String: AnyColumn<Post>] = [
        "title": .init(\.title),
        "published": .init(\.published),
        "view_count": .init(\.viewCount),
    ]   // authorID deliberately absent — not client-filterable
}
let query = try Post.where(dynamic: clientFilters)   // throws on unknown field

// Read replicas (§5.3): reads route to the replica; writes and everything
// inside a transaction use the primary (a transaction's reads must see its
// own uncommitted writes).
let repo = Repo(primary: writeClient, replica: readClient)

// Safe SQL fragments: literals are SQL, interpolations are ALWAYS binds —
// a value cannot become SQL text. Columns interpolate as identifiers;
// \(raw:) is the loud, deliberate exception.
Post.where { p in p.published && SQLFragment("char_length(\(p.title)) > \(minLength)") }

// Observability: every query logs its SQL (placeholders only — values
// never appear) at debug through the repo's logger, and records a
// `hangar.query.duration` timer dimensioned by operation
// (select/insert/update/delete/count/exists). Durations are
// dispatch-to-first-response.
let repo = Repo(client: client, logger: logger)
```

Notes: dynamic filters are equality-only by design (ranges/ordering from
untrusted input are a different, bigger surface); enum columns opt in with
one line (`extension Status: DynamicFilterConvertible {}`); `null` filters
optional columns as `IS NULL` and is rejected for non-optional ones.

## Performance

Measured, not asserted — [BENCHMARKS.md](BENCHMARKS.md) has the methodology
and the numbers. The short version:

- Building and rendering a typical query costs **~2µs**, well under 1% of a
  round trip. (It was 12–24µs before a dedicated pass; the fixes were
  precomputed identifier quoting and column lists, stored rather than
  computed schema subsets, and shared JSON coders.)
- Batched preloading is **~5×** faster than the N+1 it replaces, which is
  the design's central performance claim (§7.2) holding up under
  measurement.
- Projections are **~5×** faster than fetching whole rows — `select` earns
  its keep.
- `repo.stream(query) { }` decodes lazily for unbounded result sets: same
  throughput as `all`, flat memory. Preloads don't apply (batching needs
  every parent at once).
- **Known gap:** named prepared statements would be worth another ~2×
  on simple queries. PostgresNIO's public API requires compile-time SQL,
  so Hangar can't reach it; BENCHMARKS.md explains what closing it needs
  and why the available workaround was refused.

```
$ swift run -c release hangar-bench     # needs HANGAR_TEST_DATABASE_URL
```

## Decisions made during implementation (not in the design doc)

- **`ColumnCodable`, not `PostgresCodable`.** The design (§4.2) names
  Hangar's column-type protocol `PostgresCodable`, but PostgresNIO already
  exports a `PostgresCodable` typealias and Hangar `@_exported`-re-exports
  PostgresNIO. Renamed for exactly the §4.0 collision-avoidance reason that
  renamed `@Table` to `@Entity`.
- **Model-based `insert(model)`/`update(model)` (whole-row write by primary
  key) exist alongside the design's changeset-taking overloads** — they
  predate the `swift-changeset` extraction and remain the right tool when
  you hold a complete, trusted value.
- **`Table.queryColumns`, not `columns`.** `Hangar.Table` refines
  `Changesets.TableModel`, whose `columns` requirement is the
  `[TableColumn<Self>]` keypath catalog. Hangar's own generated column DSL
  therefore lives under `queryColumns` (users never write it — `where`
  closures receive it as `$0`). Renaming Hangar's accessor rather than
  TableModel's requirement kept the extraction a pure move with zero API
  changes for existing TableModel conformers.
- **`Multi.run` steps get the transaction repo ambiently** (`Repo.current`
  is bound while a step executes), so `Repo.require()` inside a step
  participates in the Multi's transaction. Step results are read with
  typed `MultiKey`s; duplicate step names are rejected before execution.
- **`RollbackError.intentional` rolls back and is rethrown** — the §5.2
  "converted to rollback" wrapper does not swallow it; the caller catches
  it to read the carried value. Step failures inside `repo.run(multi)`
  are returned as `.failure`, never thrown.
- **`update`/`delete` on a missing row throw `HangarError.staleModel`** —
  loud like Ecto's `StaleEntryError`, but an error, not a trap (§7.3's
  "fail one request, not the node" applied to writes).
- **A `let` property with an initializer is a compile error** — the
  generated decoder must assign every stored property, and an initialized
  `let` is already fixed. `var` with an initializer is fine (the initializer
  becomes the memberwise-init default).
- **Arrays as column types are deferred** (§4.2 lists them) to land with
  the operators that make them useful (`ANY`, containment — Phase 3/4
  territory). `swift-metrics` is likewise deferred until Phase 5 has call
  sites, per the Flight family's no-facade-deps-without-callers policy.
- **LIMIT/OFFSET render as integer literals**, not binds — they're typed
  `Int`, so there's no injection surface, and the SQL is easier to read.

## Testing

Unit and macro-fixture suites need no server:

```
$ swift test
```

Integration tests run against a real Postgres — the whole value of a query
layer is that its SQL is real. They're gated on `HANGAR_TEST_DATABASE_URL`
and skipped without it:

```
$ docker run -d --name hangar-pg -e POSTGRES_PASSWORD=hangar \
    -e POSTGRES_DB=hangar_test -p 127.0.0.1:55433:5432 postgres:16-alpine
$ export HANGAR_TEST_DATABASE_URL="postgres://postgres:hangar@127.0.0.1:55433/hangar_test?sslmode=disable"
$ swift test
```
