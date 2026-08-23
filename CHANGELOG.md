# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
