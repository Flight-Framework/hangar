import Foundation
import Logging
import Metrics
import Testing

import Hangar

// Phase 5: query logging and metrics, plus read-replica routing
//. All need a real server; the log/metric assertions ride along on
// real queries.

/// A log handler that records what Hangar emits — shared storage so the
/// handler (copied by value into the logging system) and the test both see
/// the entries.
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []

    func record(level: Logger.Level, message: String, metadata: Logger.Metadata) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((level, message, metadata))
    }

    func snapshot() -> [(level: Logger.Level, message: String, metadata: Logger.Metadata)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

struct RecordingLogHandler: LogHandler {
    let recorder: LogRecorder
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        recorder.record(
            level: event.level, message: event.message.description,
            metadata: self.metadata.merging(event.metadata ?? [:]) { _, new in new })
    }
}

/// A minimal capturing metrics backend — hand-rolled rather than pulling in
/// a test-support dependency; Hangar only emits timers.
final class TimerRecorder: MetricsFactory, TimerHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var recordings: [(label: String, dimensions: [(String, String)], nanoseconds: Int64)] = []
    private var currentTimer: (label: String, dimensions: [(String, String)])?

    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler {
        CapturingTimer(recorder: self, label: label, dimensions: dimensions)
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        fatalError("Hangar emits no counters")
    }

    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler {
        fatalError("Hangar emits no recorders")
    }

    func destroyCounter(_ handler: any CounterHandler) {}
    func destroyRecorder(_ handler: any RecorderHandler) {}
    func destroyTimer(_ handler: any TimerHandler) {}

    // TimerHandler conformance is unused directly; CapturingTimer reports here.
    func recordNanoseconds(_ duration: Int64) {}

    func record(label: String, dimensions: [(String, String)], nanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        recordings.append((label, dimensions, nanoseconds))
    }

    func snapshot() -> [(label: String, dimensions: [(String, String)], nanoseconds: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return recordings
    }

    final class CapturingTimer: TimerHandler {
        let recorder: TimerRecorder
        let label: String
        let dimensions: [(String, String)]

        init(recorder: TimerRecorder, label: String, dimensions: [(String, String)]) {
            self.recorder = recorder
            self.label = label
            self.dimensions = dimensions
        }

        func recordNanoseconds(_ duration: Int64) {
            recorder.record(label: label, dimensions: dimensions, nanoseconds: duration)
        }
    }
}

/// Bootstrapped exactly once per process — `MetricsSystem.bootstrap` allows
/// no second call. Every metrics assertion reads from this shared recorder.
let sharedTimerRecorder: TimerRecorder = {
    let recorder = TimerRecorder()
    MetricsSystem.bootstrap(recorder)
    return recorder
}()

extension PostgresIntegrationSuite {
@Suite(
    "Observability and replicas (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct ObservabilityIntegrationTests {

    @Test("each query logs its SQL at debug — placeholders, never values")
    func queryLogging() async throws {
        let recorder = LogRecorder()
        var logger = Logger(label: "hangar.test") { _ in RecordingLogHandler(recorder: recorder) }
        logger.logLevel = .debug

        let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            try await TestSchema.shared.ensure(client)
            _ = try await client.query(#"TRUNCATE "hangar_posts""#, logger: nil)

            let repo = Repo(client: client, logger: logger)
            _ = try await repo.all(Post.where { $0.title == "secret-value" })

            let hangarLines = recorder.snapshot().filter { $0.message == "hangar query" }
            #expect(hangarLines.count == 1)
            let line = try #require(hangarLines.first)
            #expect(line.level == .debug)
            let sql = try #require(line.metadata["sql"].map { "\($0)" })
            #expect(sql.contains("$1"))
            #expect(!sql.contains("secret-value"))
            #expect(line.metadata["operation"].map { "\($0)" } == "select")
            #expect(line.metadata["duration_ms"] != nil)
            group.cancelAll()
        }
    }

    @Test("each query records hangar.query.duration with its operation")
    func queryMetrics() async throws {
        try await withRepo { repo in
            let before = sharedTimerRecorder.snapshot().count
            try await repo.insert(Post.sample())
            _ = try await repo.all(Post.all)
            _ = try await repo.count(Post.all)

            let recorded = sharedTimerRecorder.snapshot().dropFirst(before)
            let operations = recorded
                .filter { $0.label == "hangar.query.duration" }
                .compactMap { entry in entry.dimensions.first(where: { $0.0 == "operation" })?.1 }
            #expect(operations.contains("insert"))
            #expect(operations.contains("select"))
            #expect(operations.contains("count"))
            #expect(recorded.allSatisfy { $0.nanoseconds > 0 })
        }
    }

    @Test("reads route to the replica; writes and transactions to the primary")
    func replicaRouting() async throws {
        // Two databases in the same server stand in for primary + replica —
        // distinguishable data proves the routing.
        let primaryClient = PostgresClient(configuration: try TestDatabase.clientConfiguration())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await primaryClient.run() }
            _ = try? await primaryClient.query(
                PostgresQuery(unsafeSQL: #"CREATE DATABASE "hangar_replica_test""#), logger: nil)

            var replicaConfig = try TestDatabase.clientConfiguration()
            replicaConfig.database = "hangar_replica_test"
            let replicaClient = PostgresClient(configuration: replicaConfig)
            group.addTask { await replicaClient.run() }

            // Same table on both sides, different marker rows.
            for sql in [
                #"DROP TABLE IF EXISTS "hangar_events""#,
                #"CREATE TABLE "hangar_events" ("id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "name" text NOT NULL)"#,
                #"INSERT INTO "hangar_events" ("name") VALUES ('replica-marker')"#,
            ] {
                _ = try await replicaClient.query(PostgresQuery(unsafeSQL: sql), logger: nil)
            }
            try await TestSchema.shared.ensure(primaryClient)
            _ = try await primaryClient.query(#"TRUNCATE "hangar_events""#, logger: nil)

            let repo = Repo(primary: primaryClient, replica: replicaClient)

            // The write lands on the primary…
            try await repo.insert(Event(name: "primary-marker"))

            // …plain reads see the replica…
            let names = try await repo.all(Event.all).map(\.name)
            #expect(names == ["replica-marker"])
            let count = try await repo.count(Event.all)
            #expect(count == 1)

            // …and reads inside a transaction see the primary, including
            // its uncommitted writes.
            let inTransaction = try await repo.transaction { tx in
                try await tx.insert(Event(name: "uncommitted"))
                return try await tx.all(Event.all).map(\.name).sorted()
            }
            #expect(inTransaction == ["primary-marker", "uncommitted"])

            group.cancelAll()
        }
    }
}
}
