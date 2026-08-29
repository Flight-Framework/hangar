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

### Batch insert: the largest ratio in this file

| | |
|---|---|
| 100 rows via one batch statement | 3.9 ms |
| 100 rows via 100 round trips | 92.3 ms |

**~24×**, and the widest margin measured anywhere in this document —
wider than preloading's, because every one of the 100 round trips pays the
same per-statement floor the preload comparison's 50 did, and there are
twice as many of them. Stable across repeated runs (21.97× and 23.6× on
two separate passes), which is worth noting explicitly: several of the
numbers in this file move with machine load, and this one does not move
much, because both sides are dominated by round-trip count rather than by
anything Postgres has to think about.

### Bulk delete and update: one statement vs. N round trips

| | |
|---|---|
| delete 20 rows via one statement | 3.0 ms |
| delete 20 rows via 20 round trips | 18.7 ms |
| update 20 rows via one statement | 1.6 ms |
| update 20 rows via 20 round trips | 19.1 ms |

**~6× for delete, ~12× for update**, both stable across two runs (6.17×/6.27×
and 11.98×/12.04×). The two ratios differ because they are not measuring
quite the same shape: the naive delete already holds the rows it is
deleting (they came back from the batch insert that seeded the group), so
its 20 round trips are 20 bare `DELETE`s. The naive update path in real code
would first have to *fetch* what it means to change; this benchmark hands
it the rows already in memory, so even this ~12× understates the naive
path's real cost against a database that also has to be read from first.

### Three-table join: no hidden per-hop cost

| | |
|---|---|
| fetch via three-table join (200 rows, 3-column projection), 200 iterations | 1.8 ms |

Phase 5 added three-table joins by extending the same renderer that already
handled two, rather than writing a second one — this is the number that
proves the extension didn't come with a per-hop tax. It lands in the same
range as this file's other small-result-set round trips rather than scaling
up with join count, which is the result the design predicts and the reason
it was worth checking rather than assuming.

### Pagination: the count is not free

| | |
|---|---|
| plain `LIMIT 20`, no count | 0.34 ms |
| `page(20 per page)` — slice + total | 0.84 ms |

`repo.page` runs the slice and the count *sequentially* — two queries from
one pool under a request-scoped connection is how a pool deadlocks under
load, and that guarantee is worth more than the round trip it costs. This is
that cost, quantified: roughly another simple query's worth, consistent
across two runs (2.46× and 2.44×). Reach for `page` because of what it
answers, not for free — a UI that never needs `page.total` should stay with
a plain `limit`.

### Soft delete and query diagnostics: opt-in features that cost nothing to leave on

| | |
|---|---|
| `SELECT` over 1000 plain rows | 0.70 ms |
| `SELECT` over 1000 soft-deletable rows | 0.73 ms |
| `SELECT` one row, diagnostics off (default) | 167 µs |
| `SELECT` one row, diagnostics on (`.recommended`) | 160 µs |

Soft delete's `deleted_at IS NULL` predicate costs a real but small amount
— **~4.5%** across two runs (4.3% and 4.7%), close enough to this
document's own stated round-trip noise floor that "small" is a more honest
word for it than a precise percentage.

Query diagnostics costs *nothing measurable*: one run showed the
diagnostics-on path 4.6% slower, the next showed it 4.2% faster — the sign
flipped between runs, which is the signature of a difference indistinguishable
from noise rather than a real one. That is the finding, stated as what it
is rather than rounded into a number that looks more precise than the data
supports: turning on `.recommended` diagnostics for a query nowhere near its
200ms threshold has no detectable cost.

### `Table.query { }` vs. `JoinedQuery3`: the wider API is also the cheaper one

The same three-table join (order ⋈ customer ⋈ item), expressed both ways.
Client-side only — the two produce the same SQL shape for Postgres to plan,
so what is actually comparable is the Swift-side cost of building and
rendering, which every call site pays before a byte reaches the wire.

| | |
|---|---|
| `JoinedQuery3`, render only | 4.53 µs |
| `ComposedQuery`, render only | 3.94 µs |
| `JoinedQuery3`, with `select(into:)` | 10.02 µs |
| `ComposedQuery`, with `select(into:)` | 8.11 µs |

**~1.15× rendering, ~1.24× projected**, and both ratios reproduced to two
decimal places on a second run (1.15× and 1.24× again) — the tightest
agreement between runs anywhere in this file, because neither side touches
the network or the allocator much.

The direction is worth a sentence, because it is the opposite of what
"erased join list" usually implies. `JoinedQuery3` carries three
`QueryColumns` values and a fixed field set through every copy, and its
`select(into:)` walks a three-argument closure's tuple; `ComposedQuery`
carries an array of small clause structs and its projection closure takes no
arguments at all. Erasure removed work here rather than adding an indirection
— but at ~4 µs against a ~300 µs round trip, this is a reason not to worry
about the wider API, not a reason to choose it.

| | |
|---|---|
| `JoinedQuery3`, 3-table join, real rows | 325 µs |
| `ComposedQuery`, same join, real rows | 321 µs |
| `ComposedQuery`, 5-table join, 240 real rows | 1.37 ms |

Against a real server the difference disappears into the round trip, as the
client-side numbers predict: 1.01× on one run and 1.05× on the next, which is
this file's noise floor rather than a finding. The extra alias qualification
`ComposedQuery` always emits (`AS "t0"`, `AS "t1"`, ... even when nothing is
ambiguous) costs Postgres's planner nothing measurable.

The five-table row is not a comparison — there is no `JoinedQuery4` to run it
against. It is here to record that arbitrary width lands in the same range as
everything else round-trip-shaped rather than scaling with join count.

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
  contention is unmeasured — including row-lock blocking
  (`lockForUpdate()`/`lockForShare()`) and isolation-level retry under real
  write-skew, both of which only show up under concurrent load and need a
  contention harness this file does not have.
- Large `IN`/`ANY` payloads beyond 1000 keys (1000 UUIDs currently costs
  ~116µs to bind, which is encoding, not Hangar overhead).
- Transactions and `Multi` throughput.
- Memory, as opposed to time.
- `EXPLAIN` itself — it wraps and (with `.analyze`) runs the query it is
  given, so timing it mostly measures Postgres's own planner and executor,
  not anything Hangar contributes.
- Schema introspection (`HangarIntrospection`) — a build-time code
  generation tool, not a runtime query path, so it has a different
  performance profile than everything else in this file and does not
  belong next to it.
- `@HasMany(through:)` round trips — not because it is unmeasured in
  substance, but because it is the same batched, two-query shape as the
  preloading numbers above, run through the same `= ANY($1)` mechanism. A
  dedicated benchmark would re-prove a ratio this file already has.
- Nullable-column ordering comparisons (`<`, `>`, `<=`, `>=` on
  `Column<V?>`) — the identical `Predicate(expression: .infix(...))` code
  path as the non-nullable overloads already benchmarked above; there is no
  new performance characteristic to isolate.
- The soft-delete scope on a *join* — the same one-term `AND (... IS NULL)`
  the single-table measurement above already priced at "small", added to an
  ON or WHERE clause that is already several terms long. Re-measuring it
  per join arity would re-prove a number this file has.
