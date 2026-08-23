import Foundation
import Testing

import Hangar

// Phase 2: transactions, savepoint nesting, RollbackError.

extension PostgresIntegrationSuite {
@Suite(
    "Transactions (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct TransactionIntegrationTests {

    @Test("returning commits; the write is visible afterwards")
    func commitOnReturn() async throws {
        try await withRepo { repo in
            let post = try await repo.transaction { tx in
                #expect(tx.isInTransaction)
                return try await tx.insert(Post.sample())
            }
            #expect(try await repo.all(Post.where { $0.id == post.id }) == [post])
        }
    }

    @Test("throwing rolls back everything the body did")
    func rollbackOnThrow() async throws {
        struct Boom: Error {}
        try await withRepo { repo in
            await #expect(throws: Boom.self) {
                try await repo.transaction { tx in
                    try await tx.insert(Post.sample())
                    try await tx.insert(Post.sample(title: "second"))
                    throw Boom()
                }
            }
            // Hoisted out of #expect: with no top-level `try` in this
            // closure, the literal would infer as non-throwing and the
            // macro-argument `try` would have no handling context.
            let remaining = try await repo.count(Post.all)
            #expect(remaining == 0)
        }
    }

    @Test("a read inside the transaction sees its uncommitted writes")
    func readYourWrites() async throws {
        try await withRepo { repo in
            try await repo.transaction { tx in
                try await tx.insert(Post.sample())
                #expect(try await tx.count(Post.all) == 1)
            }
        }
    }

    @Test("nested transaction becomes a savepoint: inner failure, outer survives")
    func savepointNesting() async throws {
        struct InnerFailure: Error {}
        try await withRepo { repo in
            let kept = try await repo.transaction { tx in
                let kept = try await tx.insert(Post.sample(title: "kept"))
                do {
                    try await tx.transaction { inner in
                        _ = try await inner.insert(Post.sample(title: "discarded"))
                        throw InnerFailure()
                    }
                } catch is InnerFailure {
                    // The savepoint rolled back; the outer transaction is
                    // healthy and can keep working — the property nested
                    // BEGINs cannot give.
                    _ = try await tx.insert(Post.sample(title: "after"))
                }
                return kept
            }
            let titles = try await repo.all(Post.all).map(\.title).sorted()
            #expect(titles == ["after", "kept"])
            #expect(try await repo.exists(Post.where { $0.id == kept.id }))
        }
    }

    @Test("two savepoint levels unwind independently")
    func deepNesting() async throws {
        struct Abort: Error {}
        try await withRepo { repo in
            try await repo.transaction { tx in
                try await tx.insert(Event(name: "level-0"))
                try await tx.transaction { inner in
                    try await inner.insert(Event(name: "level-1"))
                    do {
                        try await inner.transaction { innermost in
                            _ = try await innermost.insert(Event(name: "level-2"))
                            throw Abort()
                        }
                    } catch is Abort {}
                }
            }
            let names = try await repo.all(Event.all).map(\.name).sorted()
            #expect(names == ["level-0", "level-1"])
        }
    }

    @Test("RollbackError.intentional rolls back and reaches the caller")
    func intentionalRollback() async throws {
        try await withRepo { repo in
            do {
                try await repo.transaction { tx in
                    try await tx.insert(Post.sample())
                    throw RollbackError.intentional("not-worth-it")
                }
                Issue.record("transaction should have rethrown RollbackError")
            } catch let RollbackError.intentional(value) {
                #expect(value as? String == "not-worth-it")
            }
            #expect(try await repo.count(Post.all) == 0)
        }
    }

    @Test("the ambient repo composes with transactions")
    func ambientTransaction() async throws {
        try await withRepo { repo in
            let count = try await repo.transaction { tx in
                try await Repo.with(tx) {
                    _ = try await Repo.require().insert(Post.sample())
                    return try await Repo.require().count(Post.all)
                }
            }
            #expect(count == 1)
        }
    }
}
}

extension PostgresIntegrationSuite {
@Suite(
    "Connection-bound Repo (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct ConnectionBoundRepoTests {

    /// The  adapter shape: a repo pinned to a caller-managed connection.
    @Test("queries and transactions run on the pinned connection")
    func pinnedConnection() async throws {
        // Ensure schema/truncation via the normal harness first.
        try await withRepo { _ in }

        let config = try TestDatabase.clientConfiguration()
        var connectionConfig = PostgresConnection.Configuration(
            host: config.host ?? "127.0.0.1", port: config.port ?? 5432,
            username: config.username ?? "postgres", password: config.password,
            database: config.database, tls: .disable)
        connectionConfig.options.connectTimeout = .seconds(10)
        let connection = try await PostgresConnection.connect(
            configuration: connectionConfig, id: 1,
            logger: Logger(label: "hangar.test.conn"))
        do {
            let repo = Repo(connection: connection)
            #expect(!repo.isInTransaction)

            try await repo.insert(Post.sample(title: "pinned"))
            let count = try await repo.count(Post.all)
            #expect(count == 1)

            // transaction on a connection-bound repo opens a REAL
            // transaction (BEGIN, not a savepoint) on that connection.
            struct Abort: Error {}
            await #expect(throws: Abort.self) {
                try await repo.transaction { tx in
                    #expect(tx.isInTransaction)
                    try await tx.insert(Post.sample(title: "doomed"))
                    throw Abort()
                }
            }
            let after = try await repo.count(Post.all)
            #expect(after == 1)

            // The bug this guards: a repo bound to a connection that is
            // ALREADY inside a caller's transaction. Told nothing, it emits a
            // literal BEGIN/COMMIT — Postgres ignores the redundant BEGIN and
            // the COMMIT ends the caller's transaction, so work the caller
            // then rolls back is durable instead.
            let conn = Logger(label: "hangar.test.conn")
            _ = try await connection.query("BEGIN", logger: conn)
            let nested = Repo(connection: connection, inTransaction: true)
            #expect(nested.isInTransaction, "it must know it is inside one")

            _ = try await nested.transaction { tx in
                try await tx.insert(Post.sample(title: "should-not-survive"))
            }
            // The inner transaction released a savepoint rather than
            // committing, so the caller's transaction still owns the write.
            _ = try await connection.query("ROLLBACK", logger: conn)
            #expect(
                try await repo.count(Post.all) == 1,
                "the caller's ROLLBACK must discard work done through a nested repo")

            // The companion: the default is genuinely dangerous in this
            // position, which is why the parameter exists. Pinning it means
            // nobody removes the parameter without a red test explaining it.
            _ = try await connection.query("BEGIN", logger: conn)
            let unaware = Repo(connection: connection)  // inTransaction: false
            #expect(!unaware.isInTransaction)

            _ = try await unaware.transaction { tx in
                try await tx.insert(Post.sample(title: "escapes-the-rollback"))
            }
            _ = try await connection.query("ROLLBACK", logger: conn)
            #expect(
                try await repo.count(Post.all) == 2,
                """
                A repo that does not know it is inside a transaction emits a real \
                COMMIT, ending the caller's transaction — so this write survives a \
                ROLLBACK the caller expected to discard it. That is the hazard \
                `inTransaction:` exists to avoid.
                """)

            let committed = try await repo.transaction { tx in
                try await tx.insert(Post.sample(title: "kept"))
            }
            #expect(try await repo.exists(Post.where { $0.id == committed.id }))
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }
}
}
