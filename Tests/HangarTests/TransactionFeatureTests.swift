import Foundation
import PostgresNIO
import Testing

@testable import Hangar

// MARK: - SQL shapes

@Suite("Transactions — isolation and locking SQL")
struct TransactionRenderingTests {

    @Test("an isolation level lands on the outermost BEGIN, verbatim from the enum")
    func isolationOnBegin() {
        #expect(TransactionControl(depth: 0, isolation: .serializable).begin.sql
            == "BEGIN ISOLATION LEVEL SERIALIZABLE")
        #expect(TransactionControl(depth: 0, isolation: .repeatableRead).begin.sql
            == "BEGIN ISOLATION LEVEL REPEATABLE READ")
        #expect(TransactionControl(depth: 0, isolation: nil).begin.sql == "BEGIN")
    }

    @Test("a nested level is ignored — savepoints cannot change isolation")
    func isolationIgnoredOnSavepoints() {
        let control = TransactionControl(depth: 2, isolation: .serializable)
        #expect(control.begin.sql == "SAVEPOINT hangar_sp_2")
    }

    @Test("lockForUpdate renders FOR UPDATE at the end of the statement")
    func lockRendering() {
        let sql = SQLRenderer.select(Post.where { $0.published == true }.lockForUpdate()).sql
        #expect(sql.hasSuffix("FOR UPDATE"))
        let share = SQLRenderer.select(Post.all.lockForShare()).sql
        #expect(share.hasSuffix("FOR SHARE"))
    }

    @Test("a lock composed before a join carries through, not silently dropped")
    func lockSurvivesJoin() throws {
        let sql = try SQLRenderer.select(
            Post.all.lockForUpdate()
                .join(Comment.self, on: { p, c in c.postID == p.id })
        ).sql
        #expect(sql.hasSuffix("FOR UPDATE"))
    }

    @Test("count never locks the rows it counts")
    func countStripsLock() {
        let sql = SQLRenderer.count(Post.all.lockForUpdate().distinct()).sql
        #expect(!sql.contains("FOR UPDATE"))
    }

    @Test("bulk writes refuse a locking query — they take their own locks")
    func bulkRefusesLock() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.lockForUpdate())
        }
    }

    @Test("the escape hatch renders literals as SQL and values as binds")
    func escapeHatchBinds() {
        let statement = SQLRenderer.statement("SELECT pg_advisory_xact_lock(\(42))")
        #expect(statement.sql == "SELECT pg_advisory_xact_lock($1)")
        #expect(statement.binds.count == 1)
        // And it is NOT parenthesized like a fragment predicate would be.
        let set = SQLRenderer.statement("SET LOCAL statement_timeout = \(raw: "'5s'")")
        #expect(set.sql == "SET LOCAL statement_timeout = '5s'")
    }
}

// MARK: - Integration

/// Two tasks that must both pass a point before either proceeds.
private actor Rendezvous {
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        arrived += 1
        if arrived >= 2 {
            for waiter in waiters { waiter.resume() }
            waiters = []
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

extension PostgresIntegrationSuite {
    @Suite("Transactions — isolation, retry, escape hatch (real Postgres)")
    struct TransactionFeatureIntegrationTests {

        /// Classic write-skew: both transactions snapshot both rows, then
        /// each updates the row the *other* read. SERIALIZABLE detects the
        /// cycle and aborts one with SQLSTATE 40001 at commit.
        private func provokeWriteSkew(
            _ repo: Repo, retryAttempts: Int?
        ) async throws -> (failures: [String], values: [String]) {
            let gate = Rendezvous()
            var sqlStates: [String] = []

            await withTaskGroup(of: (any Error)?.self) { group in
                for slot in ["a", "b"] {
                    group.addTask {
                        do {
                            let body: @Sendable (Repo) async throws -> Void = { tx in
                                // Read BOTH rows, then write only ours —
                                // the other row's read is the dependency
                                // edge SSI detects.
                                let rows = try await tx.all(KV.all)
                                let total = rows.map(\.value).joined()
                                await gate.arrive()
                                _ = try await tx.update(KV.where { $0.key == slot }) {
                                    $0.value.set(to: "\(slot):saw-\(total.count)")
                                }
                            }
                            if let retryAttempts {
                                try await repo.transaction(
                                    isolation: .serializable,
                                    retryingOnSerializationFailure: retryAttempts,
                                    body)
                            } else {
                                try await repo.transaction(isolation: .serializable, body)
                            }
                            return nil
                        } catch {
                            return error
                        }
                    }
                }
                for await failure in group {
                    if let psql = failure as? PSQLError,
                        let state = psql.serverInfo?[.sqlState]
                    {
                        sqlStates.append(state)
                    } else if let failure {
                        sqlStates.append("unexpected: \(failure)")
                    }
                }
            }
            let values = try await repo.all(KV.all.order { $0.key.asc() }).map(\.value)
            return (sqlStates, values)
        }

        @Test("serializable contention surfaces SQLSTATE 40001 without retry")
        func serializationFailureSurfaces() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "a", value: "0"))
                try await repo.insert(KV(key: "b", value: "0"))
                let (failures, _) = try await provokeWriteSkew(repo, retryAttempts: nil)
                #expect(failures == ["40001"], "exactly one side should fail, with 40001")
            }
        }

        @Test("the retry wrapper recovers the losing transaction")
        func retryRecovers() async throws {
            try await withRepo { repo in
                try await repo.insert(KV(key: "a", value: "0"))
                try await repo.insert(KV(key: "b", value: "0"))
                let (failures, values) = try await provokeWriteSkew(repo, retryAttempts: 3)
                #expect(failures.isEmpty, "both sides should succeed after retry")
                #expect(values.count == 2)
                #expect(values.allSatisfy { $0.contains("saw-") })
            }
        }

        @Test("execute runs on the transaction's own connection — SET LOCAL proves it")
        func escapeHatchConnectionAffinity() async throws {
            try await withRepo { repo in
                try await repo.transaction { tx in
                    try await tx.execute("SET LOCAL statement_timeout = \(raw: "'5s'")")
                    let rows = try await tx.execute("SHOW statement_timeout")
                    for try await row in rows {
                        let value = try row.makeRandomAccess()[0].decode(String.self)
                        #expect(value == "5s", "SET LOCAL must be visible on the same connection")
                    }
                }
            }
        }

        @Test("a held FOR UPDATE lock blocks a second locking read")
        func lockActuallyLocks() async throws {
            try await withRepo { repo in
                let stored = try await repo.insert(Post.sample(title: "contested"))
                let held = Rendezvous()
                let done = Rendezvous()

                await withTaskGroup(of: String?.self) { group in
                    group.addTask {
                        try? await repo.transaction { tx in
                            _ = try await tx.all(
                                Post.where { $0.id == stored.id }.lockForUpdate())
                            await held.arrive()  // lock is held
                            await done.arrive()  // hold it until B has failed
                        }
                        return nil
                    }
                    group.addTask {
                        await held.arrive()
                        defer { Task { await done.arrive() } }
                        do {
                            try await repo.transaction { tx in
                                // Fail fast instead of queueing behind A.
                                try await tx.execute("SET LOCAL lock_timeout = \(raw: "'200ms'")")
                                _ = try await tx.all(
                                    Post.where { $0.id == stored.id }.lockForUpdate())
                            }
                            return "acquired"
                        } catch let error as PSQLError {
                            return error.serverInfo?[.sqlState]
                        } catch {
                            return "unexpected"
                        }
                    }
                    var outcomes: [String?] = []
                    for await outcome in group { outcomes.append(outcome) }
                    // 55P03: lock_not_available — the lock was genuinely held.
                    #expect(outcomes.contains("55P03"))
                }
            }
        }
    }
}
