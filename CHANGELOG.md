# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
