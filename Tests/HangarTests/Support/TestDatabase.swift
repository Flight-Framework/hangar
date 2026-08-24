import Foundation
import Logging
import Hangar
import PostgresNIO
import Testing

/// The enclosing suite every DB-touching suite nests in (via extension).
/// `.serialized` on the parent applies recursively, so suites that share
/// the fixture tables never truncate them under each other — same pattern
/// as flight-data-postgres's `PostgresIntegrationSuite`.
@Suite(.serialized) struct PostgresIntegrationSuite {}

/// Integration tests run against a real Postgres — the whole value of a
/// query layer is that its SQL is real; mocking the connection would test
/// nothing that matters. Gated on `HANGAR_TEST_DATABASE_URL`:
///
/// ```
/// $ docker run -d --name hangar-pg -e POSTGRES_PASSWORD=hangar \
///     -e POSTGRES_DB=hangar_test -p 127.0.0.1:55433:5432 postgres:16-alpine
/// $ export HANGAR_TEST_DATABASE_URL="postgres://postgres:hangar@127.0.0.1:55433/hangar_test?sslmode=disable"
/// $ swift test
/// ```
///
/// Without the variable, the integration suite is skipped and only the
/// no-server unit tests run.
enum TestDatabase {
    static let url = ProcessInfo.processInfo.environment["HANGAR_TEST_DATABASE_URL"]

    static var isConfigured: Bool { url != nil }

    static func clientConfiguration() throws -> PostgresClient.Configuration {
        guard let url, let components = URLComponents(string: url) else {
            throw TestDatabaseError.notConfigured
        }
        return PostgresClient.Configuration(
            host: components.host ?? "127.0.0.1",
            port: components.port ?? 5432,
            username: components.user ?? "postgres",
            password: components.password,
            database: components.path.isEmpty ? nil : String(components.path.dropFirst()),
            tls: .disable)
    }
}

enum TestDatabaseError: Error {
    case notConfigured
}


/// Serializes every test that touches the database.
///
/// `withRepo` truncates the fixture tables, so two suites running at the same
/// time delete each other's rows — and swift-testing runs suites in parallel.
/// `.serialized` on a suite only orders the tests *within* it, so the barrier
/// has to be here, around the shared resource itself.
///
/// This was latent rather than new: it stayed hidden while the integration
/// suites were few and while CI ran without HANGAR_TEST_DATABASE_URL, where
/// every one of them skips.
actor DatabaseLock {
    static let shared = DatabaseLock()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Runs `body` with exclusive use of the fixture tables.
    func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// Runs `body` with a started client and a `Repo` on it, ensuring the
/// fixture schema exists and the tables are empty.
func withRepo<T: Sendable>(_ body: @Sendable (Repo) async throws -> T) async throws -> T {
    try await DatabaseLock.shared.exclusive {
        try await withRepoUnlocked(body)
    }
}

private func withRepoUnlocked<T: Sendable>(
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            try await TestSchema.shared.ensure(client)
            _ = try await client.query(
                #"TRUNCATE "hangar_posts", "hangar_events", "hangar_authors", "hangar_comments", "hangar_profiles", "hangar_kv", "hangar_tagged", "hangar_tags", "hangar_post_tags", "hangar_tagged_posts", "hangar_files""#,
                logger: nil)
            let result = try await body(Repo(client: client))
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Like ``withRepo(_:)``, with a logger and diagnostics attached — for the
/// suites that assert on what Hangar reports rather than on what it returns.
func withRepo<T: Sendable>(
    logger: Logger,
    diagnostics: QueryDiagnostics,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    try await DatabaseLock.shared.exclusive {
        try await withRepoUnlocked(logger: logger, diagnostics: diagnostics, body)
    }
}

private func withRepoUnlocked<T: Sendable>(
    logger: Logger,
    diagnostics: QueryDiagnostics,
    _ body: @Sendable (Repo) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: try TestDatabase.clientConfiguration())
    return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        do {
            try await TestSchema.shared.ensure(client)
            _ = try await client.query(
                #"TRUNCATE "hangar_posts", "hangar_events", "hangar_authors", "hangar_comments", "hangar_profiles", "hangar_kv", "hangar_tagged", "hangar_tags", "hangar_post_tags", "hangar_tagged_posts", "hangar_files""#,
                logger: nil)
            var repo = Repo(client: client, logger: logger)
            repo.diagnostics = diagnostics
            let result = try await body(repo)
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Creates the fixture schema once per process.
actor TestSchema {
    static let shared = TestSchema()
    private var done = false

    func ensure(_ client: PostgresClient) async throws {
        guard !done else { return }
        let statements = [
            #"DROP TABLE IF EXISTS "hangar_files""#,
            #"DROP TABLE IF EXISTS "hangar_posts""#,
            #"DROP TABLE IF EXISTS "hangar_events""#,
            #"DROP TABLE IF EXISTS "hangar_authors""#,
            #"DROP TABLE IF EXISTS "hangar_comments""#,
            #"DROP TABLE IF EXISTS "hangar_profiles""#,
            #"DROP TABLE IF EXISTS "hangar_kv""#,
            #"DROP TABLE IF EXISTS "hangar_tagged""#,
            #"DROP TABLE IF EXISTS "hangar_tags""#,
            #"DROP TABLE IF EXISTS "hangar_post_tags""#,
            #"DROP TABLE IF EXISTS "hangar_tagged_posts""#,
            #"DROP TYPE IF EXISTS "post_status""#,
            #"CREATE TYPE "post_status" AS ENUM ('draft', 'published', 'archived')"#,
            #"""
            CREATE TABLE "hangar_files" (
                "id" uuid PRIMARY KEY,
                "name" text NOT NULL,
                "size_bytes" integer NOT NULL,
                "deleted_at" timestamptz
            )
            """#,
            #"""
            CREATE TABLE "hangar_posts" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "title" text NOT NULL,
                "published" boolean NOT NULL,
                "view_count" bigint NOT NULL,
                "created_at" timestamptz NOT NULL,
                "nickname" text,
                "status" post_status NOT NULL,
                "metadata" jsonb NOT NULL,
                "author_id" uuid NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_events" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "name" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_authors" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_comments" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "post_id" uuid NOT NULL,
                "author_id" uuid NOT NULL,
                "moderator_id" uuid,
                "body" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_profiles" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "author_id" uuid NOT NULL,
                "bio" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_kv" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "key" text NOT NULL UNIQUE,
                "value" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_tagged" (
                "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                "name" text NOT NULL,
                "labels" text[] NOT NULL,
                "scores" bigint[] NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_tags" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "label" text NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_post_tags" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "post_id" uuid NOT NULL,
                "tag_id" uuid NOT NULL
            )
            """#,
            #"""
            CREATE TABLE "hangar_tagged_posts" (
                "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                "title" text NOT NULL
            )
            """#,
        ]
        for sql in statements {
            _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: nil)
        }
        done = true
    }
}
