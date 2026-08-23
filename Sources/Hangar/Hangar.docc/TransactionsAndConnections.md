# Transactions and connections

Nesting, savepoints, and the one thing you must tell a connection-bound repo.

## Overview

``Repo/transaction(_:)`` runs a body inside a transaction. Returning commits;
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

## What is missing

There is no escape hatch for running arbitrary SQL *inside* a transaction —
`SET LOCAL`, an advisory lock, `SELECT … FOR UPDATE`, DDL. The transaction's
connection is not reachable from the body, so those are currently out of
reach. This is a known gap.

There is also no isolation-level control; every transaction runs at the server
default. `SERIALIZABLE` with retry-on-40001 is the standard answer for
write-skew, and it is not expressible yet.
