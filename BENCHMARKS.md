# Hangar — performance

Run them yourself:

```
$ docker start hangar-pg
$ export HANGAR_TEST_DATABASE_URL="postgres://postgres:hangar@127.0.0.1:55433/hangar_test?sslmode=disable"
$ swift run -c release hangar-bench
```

`-c release` matters: a debug build measures the optimizer being off, and
the harness prints a warning if you forget. Without the environment
variable the client-side benchmarks still run; the round-trip ones skip.

## How to read the numbers

Two families, deliberately separated because they answer different
questions and have very different noise floors:

- **Client-side** — what Hangar itself costs: building a query value and
  rendering it to SQL + binds. No server, so these are stable, repeatable,
  and attributable to Hangar's own code. Trust these to ±5%.
- **Round trip** — end-to-end latency against a real server. These move
  around with machine load, Docker networking, and Postgres's own state;
  across runs on the same machine we saw the same query measure anywhere
  from 180µs to 710µs. Use them for *ratios within a single run*, never as
  absolute figures, and never to compare two runs.

All figures below are from one run on Linux / Swift 6.2.3 / Postgres 16 in
Docker on localhost. Your absolute numbers will differ; the ratios are the
point.

## Where the time goes

### Client-side: ~2µs to build and render a typical query

| | |
|---|---|
| trivial select | 0.41 µs |
| select + 2-term where | 2.13 µs |
| where + order + limit | 2.63 µs |
| projection (3 columns) | 2.65 µs |
| insert (11 columns) | 2.37 µs |
| render + apply binds → `PostgresQuery` | 2.78 µs |

Against a round trip measured in hundreds of microseconds, Hangar's own
overhead is well under 1% of a query's cost. The ergonomics are not being
paid for in latency.

**This was not true before the performance pass.** The same measurements
started at 12–24µs, and the fixes were mundane:

| | before | after | |
|---|---|---|---|
| trivial select | 12.38 µs | 0.41 µs | **30×** |
| select + 2-term where | 14.91 µs | 2.13 µs | **7×** |
| insert (11 columns) | 23.92 µs | 2.37 µs | **10×** |
| render + binds | 15.37 µs | 2.78 µs | **5.5×** |

What was wrong, in order of impact:

1. **`quote()` called Foundation's `replacingOccurrences` per column, per
   query.** It is slow enough on Linux to dominate everything else in
   rendering. Identifiers are now quoted **once**, when the schema is
   built, and the runtime path has a fast branch that avoids Foundation
   entirely for identifiers without embedded quotes.
2. **Column lists were rebuilt on every query** — `map` + `joined` over
   every column, for the SELECT list and again for RETURNING.
   `TableSchema` now precomputes them as strings at construction.
3. **`insertable` / `updatable` / `primaryKey` were computed properties**
   that re-filtered the column array on every access, several times per
   write. Now stored, computed once.
4. **A fresh `JSONEncoder`/`JSONDecoder` per `@JSONB` value.** Now shared.

The giveaway was in the original numbers: a 3-column projection rendered
*faster* than a plain select of the same table, because the projection
never touched the whole-column-list path. Worth remembering as a
debugging pattern — the cheap case being slower than the expensive one
points straight at what's actually expensive.

### Preloading: 5× on the shape it exists for

| | |
|---|---|
| preload 50 authors × 4 posts (2 queries) | 2.24 ms |
| naive one-query-per-parent (1 + 50 queries) | 11.10 ms |

This is the design's central performance claim and it holds: the
cost of N+1 is N round trips, and batching removes them. Note the earlier
version of this benchmark compared the two over a data set where one
author owned 1000 posts — both paths then decoded the same ~1200 rows, the
round-trip difference was swamped, and preload looked *slower*. A
benchmark that isn't isolating what it claims is worse than none.

### Projections: fetch what you need

| | |
|---|---|
| 1000 rows, all 11 columns | 10.12 ms |
| 1000 rows, 2 columns | 2.12 ms |

~5× for asking for less. `select` is not a nicety.

### Streaming: same speed, flat memory

| | |
|---|---|
| `all()` — materialize 1000 rows | 7.27 ms |
| `stream()` — decode 1000 rows lazily | 7.50 ms |

Identical throughput, as expected — the win is that `stream` never holds
more than one row, so the memory cost of a million-row export is constant
rather than a million models. Use `all` by default; reach for `stream`
when the result set is unbounded.

## The one gap we did not close: prepared statements

| | |
|---|---|
| unnamed statement (what Hangar sends today) | 240 µs |
| named prepared statement, identical SQL | 98 µs |

**Roughly 2–2.5× on a simple keyed lookup**, measured by running the exact
SQL Hangar generates down both paths. Postgres parses and plans an unnamed
statement on every execution; a named one is planned once.

That is a large number, and Hangar cannot currently reach it.
PostgresNIO's prepared-statement API is `PostgresPreparedStatement`, whose
`sql` and `name` are **static** requirements — designed for SQL known at
compile time. Hangar's SQL is composed at runtime from a query value,
which is the entire point of the library. The runtime-name path
(`PostgresConnection.prepareStatement(_:with:logger:)`) exists but is
internal to PostgresNIO.

There is a trick that would work today: `static var sql` is a *computed*
requirement, so a conforming type could read it from a task-local set
around the `execute` call. **We are deliberately not doing this.** It
depends on PostgresNIO reading those statics on the caller's task, which
is an undocumented implementation detail, and the failure mode if that
ever changes is not a crash or a compile error — it is *executing the
wrong SQL*. That is an unacceptable risk in the layer that talks to the
database.

Closing this properly needs one of:

- an upstream PostgresNIO API taking `name`/`sql` as runtime values
  (the internal plumbing already does — `HandlerTask.executePreparedStatement`
  carries both as ordinary parameters), or
- session-level `PREPARE`/`EXECUTE` managed by Hangar, which requires
  per-connection statement tracking that the pooled `PostgresClient` does
  not expose a hook for, plus recovery when a cached name turns out not to
  exist on a recycled connection.

Recorded here rather than hidden: it is the single largest remaining
performance item, it is quantified, and the fix is upstream rather than
local.

## What is not measured yet

- Concurrency: everything here is sequential. Pool behavior under
  contention is unmeasured.
- Large `IN`/`ANY` payloads beyond 1000 keys (1000 UUIDs currently costs
  ~116µs to bind, which is encoding, not Hangar overhead).
- Transactions and `Multi` throughput.
- Memory, as opposed to time.
