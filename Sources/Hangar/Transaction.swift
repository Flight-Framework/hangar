import Logging
import PostgresNIO

// Transactions. The `Repo` handed to the body is bound to the
// transaction's connection, so everything inside participates. Throwing
// rolls back; returning commits. Nested `transaction` calls become
// savepoints (`SAVEPOINT` / `RELEASE` / `ROLLBACK TO`), never nested
// `BEGIN`s.

extension Repo {
    public func transaction<T: Sendable>(
        _ body: (Repo) async throws -> T
    ) async throws -> T {
        switch backend {
        case .client(let primary, _):
            // One connection leased from the PRIMARY for the whole
            // transaction — a replica never sees writes — and every
            // statement in `body` runs on it. The control flow is inlined
            // here (rather than shared with the branch below) so `body` is
            // *called* inside the lease closure, never passed across it —
            // region isolation rejects the round trip.
            return try await primary.withConnection { connection in
                let control = TransactionControl(depth: 0)
                let log = logger ?? Self.quietLogger
                _ = try await connection.query(control.begin, logger: log)
                let tx = Repo(transaction: connection, depth: 1, logger: logger)
                do {
                    let result = try await body(tx)
                    _ = try await connection.query(control.commit, logger: log)
                    return result
                } catch {
                    // Roll back and surface the body's error. If the
                    // rollback itself fails the connection is beyond saving
                    // — the pool discards it, and the original error is
                    // still the story.
                    _ = try? await connection.query(control.rollback, logger: log)
                    throw error
                }
            }
        case .transaction(let connection, let depth):
            let control = TransactionControl(depth: depth)
            let log = logger ?? Self.quietLogger
            _ = try await connection.query(control.begin, logger: log)
            let tx = Repo(transaction: connection, depth: depth + 1, logger: logger)
            do {
                let result = try await body(tx)
                _ = try await connection.query(control.commit, logger: log)
                return result
            } catch {
                _ = try? await connection.query(control.rollback, logger: log)
                throw error
            }
        }
    }
}

/// The statement triple for one nesting level: `BEGIN`/`COMMIT`/`ROLLBACK`
/// at the outermost level, savepoint forms inside. Savepoint names are
/// generated from the depth — never from user input.
struct TransactionControl {
    let begin: PostgresQuery
    let commit: PostgresQuery
    let rollback: PostgresQuery

    init(depth: Int) {
        if depth == 0 {
            begin = "BEGIN"
            commit = "COMMIT"
            rollback = "ROLLBACK"
        } else {
            let name = "hangar_sp_\(depth)"
            begin = PostgresQuery(unsafeSQL: "SAVEPOINT \(name)")
            commit = PostgresQuery(unsafeSQL: "RELEASE SAVEPOINT \(name)")
            rollback = PostgresQuery(unsafeSQL: "ROLLBACK TO SAVEPOINT \(name)")
        }
    }
}

/// Explicit rollback without a failure condition:
///
/// ```swift
/// throw RollbackError.intentional(reason)
/// ```
///
/// The transaction wrapper converts it to a rollback like any other thrown
/// error and rethrows it, so the caller can catch it and read the carried
/// value. Cleaner than Ecto's `Repo.rollback/1`, which needs a non-local
/// return mechanism — Swift's throws express it directly.
public enum RollbackError: Error, Sendable {
    case intentional(any Sendable)
}
