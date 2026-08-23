# Transactions and connections

Nesting, savepoints, and the one thing you must tell a connection-bound repo.

## Overview

``Repo/transaction(isolation:_:)`` runs a body inside a transaction. Returning commits;
throwing rolls back:

```swift
try await repo.transaction { tx in
    try await tx.insert(order)
    try await tx.insert(payment)      // a throw here discards the order too
}
```

The `tx` handed to the body is a repo bound to the transaction's connection.
Use it — not the outer repo — for everything inside, or the work runs outside
the transaction.

## Nesting uses savepoints

A `transaction` inside a `transaction` becomes a `SAVEPOINT`, so an inner
failure can be caught and handled without discarding the outer work:

```swift
try await repo.transaction { tx in
    try await tx.insert(order)

    do {
        try await tx.transaction { inner in       // SAVEPOINT
            try await inner.insert(optionalExtra)
        }
    } catch {
        // The savepoint rolled back. The order is still there.
    }
}
```

Savepoint names are generated from the nesting depth, never from user input.

## Binding a repo to a connection you own

A repo normally holds a pool. It can instead be pinned to a single connection
you manage — the shape a framework uses to bind one to a request scope:

```swift
let repo = Repo(connection: connection)
```

> Important: **If that connection is already inside a transaction, say so.**
>
> ```swift
> Repo(connection: connection, inTransaction: true)
> ```
>
> At the default the repo believes it is outermost, so `transaction { }` emits
> a literal `BEGIN`/`COMMIT`. Postgres warns and ignores the redundant
> `BEGIN` — and the `COMMIT` then ends *your* transaction. Work you intended
> to roll back is durable instead, with nothing thrown and nothing logged.
>
> With `inTransaction: true` it nests as a savepoint, which is what it should
> have been.
>
> Hangar cannot detect this itself: PostgresNIO does not expose the
> connection's transaction status. The caller knows, so the caller says.

``Repo/isInTransaction`` reports what the repo believes, which is a useful
thing to assert in an integration's tests.

## Isolation levels and retry

The level rides on the outermost `BEGIN` — nested calls are savepoints and
cannot change it:

```swift
try await repo.transaction(isolation: .serializable) { tx in ... }
```

Under `SERIALIZABLE`, concurrent conflicting transactions fail with SQLSTATE
`40001` — that is the isolation level working as designed, and the remedy is
to run the whole transaction again:

```swift
try await repo.transaction(
    isolation: .serializable, retryingOnSerializationFailure: 3
) { tx in ... }
```

The body must be safe to run more than once; side effects outside the
database do not roll back, so keep them out of retried bodies.

## Raw SQL on the transaction's connection

``Repo/execute(_:)`` runs one statement under `SQLFragment`'s interpolation
rules — literals become SQL, values become binds, only `\(raw:)` can smuggle
text. Inside `transaction { }` it runs on **that transaction's connection**,
which is what `SET LOCAL`, advisory locks, and DDL need:

```swift
try await repo.transaction { tx in
    try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
    try await tx.execute("SELECT pg_advisory_xact_lock(\(42))")
    ...
}
```

## Row locks

`FOR UPDATE` is first-class, not raw SQL — typed, discoverable, and routed
to the primary:

```swift
try await repo.transaction { tx in
    let account = try await tx.one(Account.where { $0.id == id }.lockForUpdate())
    // the row is ours until commit
}
```

A lock composed before a join carries through; `count` strips it (counting
must not lock); bulk writes refuse it — they take their own locks.
