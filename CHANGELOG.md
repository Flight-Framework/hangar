# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Three-table joins.** `.join`/`.leftJoin` on any two-table join adds a
  third table, the on-closure and every later composition closure seeing all
  three column sets. Aliases work on any side, the ambiguity guard extends
  three ways, projections and preloads carry through, and `count`/`exists`
  follow the same clause rules as everywhere else. Ordinary generics, not a
  parameter-pack generalization: a compile spike confirmed a stored pack
  cannot be re-expanded into the on-closure call in this Swift version, so
  the pack form would compromise exactly the ergonomics that matter.
- **`DISTINCT ON`.** `distinct(on: { $0.authorID })` on single-table and
  joined queries alike — the "newest row per group" shape. Last-call-wins
  with `.distinct()`, counted through a subquery, refused by bulk writes.
- **`exists` for joined queries**, which had `count` but no `exists`.
- **Self-joins, via table aliases.** `Post.alias("parent").join(Post.alias("child"), on: ...)`
  renders `FROM "posts" AS "parent" JOIN "posts" AS "child"`, with every
  column reference — in the ON condition, later `.where`/`.order`/`.groupBy`
  closures, and the base entity's select list — qualified by its alias.
  Aliases are equally allowed on ordinary joins. An unaliased self-join is
  still refused, now with the remedy named; two sides aliased to the same
  name are refused too. The `@Entity`-generated `Columns` struct gained
  `init(table:)` (the `AliasableColumns` conformance) to make aliased column
  sets constructible; `Table.QueryColumns` is now constrained to it, which
  is source-breaking only for hand-written `Table` conformances — `@Entity`
  regenerates automatically.
- **Transaction isolation levels and retry.**
  `repo.transaction(isolation: .serializable) { }` applies the level to the
  outermost `BEGIN` (nested calls are savepoints and cannot change it), and
  `transaction(isolation:retryingOnSerializationFailure:_:)` re-runs the
  whole transaction on SQLSTATE `40001`/`40P01` — the standard SERIALIZABLE
  pattern, verified by a real write-skew contention test.
- **In-transaction escape hatch.** `repo.execute("SET LOCAL ...")` runs one
  raw statement, bind-safe under `SQLFragment`'s interpolation rules, on the
  transaction's own connection — which is what `SET LOCAL`, advisory locks,
  and DDL need, with no raw connection ever exposed.
- **Row locks as first-class query modifiers.** `Query.lockForUpdate()` /
  `.lockForShare()`. A locking read always routes to the primary, carries
  through joins rather than being silently dropped, is stripped from `count`
  (counting must not lock), and is refused by bulk writes (which take their
  own locks).
- **Bulk `update(query, set:)`.** One statement across every matching row,
  with typed, bound assignments and the row count returned:
  `repo.update(Post.where { $0.published == false }) { ($0.published.set(to: true)) }`.
  Same clause rules as bulk delete.
- **Bulk `delete(query)`.** `repo.delete(Session.where { $0.expiresAt < .now })`
  deletes every matching row in one statement and returns the count. A query
  carrying a clause DELETE cannot honor — LIMIT, ORDER BY, GROUP BY, HAVING,
  DISTINCT — throws `HangarError.bulkWriteClause` rather than executing with
  the clause silently dropped.
- **Array column types.** `@Column var tags: [String]` maps to `text[]`, and
  likewise for `Bool`, `Int`/`Int16`/`Int32`/`Int64`, `Float`, `Double`,
  `UUID`, and `Date` elements — exactly the set PostgresNIO can code into a
  Postgres array. `Decimal` and `Data` have no array coding upstream, so
  `numeric[]`/`bytea[]` columns remain unsupported.

### Added (safety)

- **Escaped streams fail loudly.** `PostgresRowStream` is an ordinary
  `Sendable` struct, and Swift's `AsyncSequence` cannot be conformed to by a
  non-escapable type — so copying one out of its `stream { }` closure cannot
  be a compile error in this language version (verified against the 6.2.3
  stdlib's protocol declarations). It is now a runtime one: the connection
  lease expires when the closure returns, and the first `next()` after that
  throws `HangarError.streamLeaseExpired` instead of reading rows from a
  connection another query now owns.

### Changed

- **`MultiValues`' subscript throws instead of trapping.** A step reading a
  key whose step hasn't run, or a mistyped key, now fails that Multi's
  transaction and reports through `MultiResult.failure` — the right blast
  radius for a wiring bug discovered inside a live transaction is one rolled
  back transaction, not an aborted process. Call sites gain a `try`.

### Fixed

- **`SQLFragment` columns render table-qualified in multi-table scopes.**
  A fragment like `SQLFragment("char_length(\(p.title)) > \(n)")` inside a
  join previously rendered a bare `"title"` — ambiguous at best, silently
  resolved to the wrong table at worst. Qualification is now decided at
  render time, exactly as for columns outside fragments.

### Fixed

- **Joined `count` honored none of GROUP BY / HAVING / DISTINCT.** The
  single-table `count` was fixed in the last pass; the joined one still
  hand-rolled its SQL and ignored all three. Both now share the same rule:
  clauses that change what a row is count through a subquery.
- **`count` over a grouped, unprojected query now emits valid SQL.** It
  used to render the full column list inside the subquery — which Postgres
  rejects, since ungrouped columns can't appear — so the count that should
  have said "2 groups" said "ERROR". The grouping expressions themselves
  are the inner select list now: one row per group is exactly what is being
  counted.

### Fixed — silent wrong answers

Three bugs that rendered valid SQL and returned the wrong result. Nothing
threw and nothing logged, which is what makes this class of bug worth its own
test suite.

- **A join discarded the `GROUP BY` and `HAVING` it was composed from.**
  `Post.groupBy { … }.join(…)` produced an ungrouped, unfiltered query. Building
  the join first happened to work, so composition order silently changed the
  result — and the documented example was written in the order that broke.
- **`count` and `exists` ignored `GROUP BY`, `HAVING`, and `DISTINCT`.** Each
  changes what a row is, so counting without them answers a different question:
  a `count` over a grouped query returned 3 where the correct answer was 1.
  Those queries are now counted as a subquery. Ordering, limit, and offset are
  still ignored, because they do not change how many rows match.
- **A connection-bound `Repo` committed its caller's transaction.**
  `Repo(connection:)` assumed it was outermost, so `transaction { }` emitted a
  literal `BEGIN`/`COMMIT`. Handed a connection already inside a transaction —
  exactly what a framework integration does — Postgres ignored the redundant
  `BEGIN` and the `COMMIT` ended the caller's transaction, making writes the
  caller then rolled back durable.

  `Repo(connection:inTransaction:)` fixes it. Hangar cannot detect this
  itself, because PostgresNIO does not expose the connection's transaction
  status, so the caller declares it.

### Changed

- **`JoinedQuery2` is now `JoinedQuery`.** The `2` was arity, not a version,
  and every reader assumed otherwise.
- `HangarError` conforms to `LocalizedError`, so `localizedDescription` carries
  the real message rather than a Foundation placeholder.
- Diagnostic messages no longer cite internal design-document sections.

### Removed

- `SQLRenderer_quoteForTest`, a public global that existed only for a test that
  can use `@testable`.
- `TableSchema.insertPlaceholders`, computed for every schema and never read.

### Added

- `SilentWrongAnswerTests`, pinning all three bugs above — including a test
  that deliberately demonstrates the *hazardous* default of
  `Repo(connection:)`, so the parameter cannot be removed without a red test
  explaining what it was for.
- DocC catalog with two guides: preloading, and transactions and connections.
- LICENSE, CI with a Postgres service container, CONTRIBUTING, CHANGELOG.

### Documentation

- README rewritten for an external reader; it was a monorepo status log. It now
  states plainly what is missing — bulk writes, an in-transaction escape hatch,
  isolation levels, CTEs, three-table joins.
- All internal design-document references removed from source, tests, README,
  and benchmarks, including ones in test names that appear in CI output.
