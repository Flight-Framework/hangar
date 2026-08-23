import Foundation
import Hangar
import PostgresNIO

// Hangar's benchmark harness. Two families of measurement, deliberately
// separated because they answer different questions:
//
//   Client-side  — what Hangar itself costs: rendering a query to SQL,
//                  decoding rows. No server involved, so the numbers are
//                  stable and attributable.
//   Round-trip   — what a query costs end to end, which tells you what
//                  fraction of real-world latency the client-side work
//                  actually represents.
//
// Run: swift run -c release hangar-bench
// Release matters: a debug build measures the optimizer being off.

// MARK: - Fixtures

enum BenchStatus: String, PostgresEnum { case draft, published }

struct BenchMeta: Codable, Sendable {
    var tags: [String]
    var score: Int
}

@Entity("bench_posts")
struct BenchPost: Sendable {
    @ID let id: UUID
    var title: String
    var body: String
    var published: Bool
    var viewCount: Int
    var rank: Int
    @Column("created_at") var createdAt: Date
    var nickname: String?
    var status: BenchStatus
    @JSONB var metadata: BenchMeta
    var authorID: UUID
}

@Entity("bench_authors")
struct BenchAuthor: Sendable {
    @ID let id: UUID
    var name: String

    @HasMany(foreignKey: \BenchPost.authorID)
    var posts: Loadable<[BenchPost]>
}

// MARK: - Timing

/// Runs `body` `iterations` times after a warmup pass and reports the mean.
/// Warmup matters: the first call pays one-time lazy-initialization costs
/// (static metadata, first-touch allocations) that would otherwise smear
/// across a short run.
@discardableResult
func measure(
    _ name: String,
    iterations: Int,
    warmup: Int = 100,
    _ body: () throws -> Void
) rethrows -> Duration {
    for _ in 0..<warmup { try body() }
    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        for _ in 0..<iterations { try body() }
    }
    report(name, elapsed / iterations, iterations: iterations)
    return elapsed / iterations
}

@discardableResult
func measureAsync(
    _ name: String,
    iterations: Int,
    warmup: Int = 5,
    _ body: () async throws -> Void
) async throws -> Duration {
    for _ in 0..<warmup { try await body() }
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0..<iterations { try await body() }
    let elapsed = clock.now - start
    report(name, elapsed / iterations, iterations: iterations)
    return elapsed / iterations
}

func report(_ name: String, _ per: Duration, iterations: Int) {
    let nanos = Double(per.components.attoseconds) / 1e9 + Double(per.components.seconds) * 1e9
    let rendered: String
    if nanos < 1_000 {
        rendered = String(format: "%7.0f ns", nanos)
    } else if nanos < 1_000_000 {
        rendered = String(format: "%7.2f µs", nanos / 1_000)
    } else {
        rendered = String(format: "%7.2f ms", nanos / 1_000_000)
    }
    print("  \(name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(rendered)   (n=\(iterations))")
}

func section(_ title: String) {
    print("\n\(title)")
    print(String(repeating: "─", count: 72))
}

// MARK: - Client-side benchmarks (no server)

func sampleModel() -> BenchPost {
    BenchPost(
        id: UUID(),
        title: "a reasonably typical title",
        body: String(repeating: "lorem ipsum ", count: 20),
        published: true,
        viewCount: 42,
        rank: 3,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        nickname: nil,
        status: .published,
        metadata: BenchMeta(tags: ["swift", "postgres"], score: 9),
        authorID: UUID())
}

func clientSideBenchmarks() throws {
    section("Client-side: query rendering (what Hangar costs before the wire)")

    measure("build + render trivial select", iterations: 100_000) {
        blackHole(BenchPost.all.debugSQL)
    }

    measure("build + render select + 2-term where", iterations: 100_000) {
        blackHole(BenchPost.where { $0.published && $0.viewCount > 100 }.debugSQL)
    }

    measure("build + render where + order + limit", iterations: 100_000) {
        blackHole(
            BenchPost.where { $0.published && $0.viewCount > 100 }
                .order { $0.createdAt.desc() }
                .limit(20)
                .debugSQL)
    }

    measure("build + render projection (3 columns)", iterations: 100_000) {
        blackHole(
            BenchPost.where { $0.published }.select { ($0.id, $0.title, $0.viewCount) }.debugSQL)
    }

    let model = sampleModel()
    try measure("render insert (11 columns)", iterations: 100_000) {
        blackHole(try model.debugInsertSQL())
    }

    section("Client-side: render + bind application (everything before the wire)")

    try measure("select + 2 binds → PostgresQuery", iterations: 100_000) {
        blackHole(try BenchPost.where { $0.published && $0.viewCount > 100 }.renderedQuery())
    }

    try measure("preload-shaped ANY($1) over 1000 keys", iterations: 10_000) {
        blackHole(try BenchPost.where { $0.authorID.in(benchKeys) }.renderedQuery())
    }
}

let benchKeys: [UUID] = (0..<1_000).map { _ in UUID() }

// The prepared-statement protocol demands a *static* SQL string; Hangar's
// is built at runtime. This global is the seam that lets the benchmark
// compare like with like — and is precisely the reason Hangar itself
// cannot use this API (see BENCHMARKS.md).
nonisolated(unsafe) var preparedStatementSQL = ""
nonisolated(unsafe) var benchClient: PostgresClient!

@inline(never)
func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}

// MARK: - Round-trip benchmarks (real server)

func roundTripBenchmarks(_ repo: Repo) async throws {
    section("Round trip: single-row queries (client cost vs. total latency)")

    let authorID = UUID()
    try await repo.insert(BenchAuthor(id: authorID, name: "bench"))
    var seeded: [BenchPost] = []
    for index in 0..<1_000 {
        var post = sampleModel()
        post.viewCount = index
        post.authorID = authorID
        seeded.append(try await repo.insert(post))
    }
    let target = seeded[500]

    try await measureAsync("SELECT one row by primary key", iterations: 500) {
        blackHole(try await repo.one(BenchPost.where { $0.id == target.id }))
    }

    try await measureAsync("SELECT one row, 3-column projection", iterations: 500) {
        blackHole(
            try await repo.one(
                BenchPost.where { $0.id == target.id }.select { ($0.id, $0.title, $0.viewCount) }))
    }

    try await measureAsync("count(*) over 1000 rows", iterations: 500) {
        blackHole(try await repo.count(BenchPost.all))
    }

    section("Round trip: result-set decoding (per-row decode cost)")

    for limit in [10, 100, 1_000] {
        try await measureAsync("fetch \(limit) full rows (11 columns)", iterations: limit >= 1_000 ? 50 : 200) {
            blackHole(try await repo.all(BenchPost.order { $0.viewCount.asc() }.limit(limit)))
        }
        try await measureAsync("fetch \(limit) rows, 2-column projection", iterations: limit >= 1_000 ? 50 : 200) {
            blackHole(
                try await repo.all(
                    BenchPost.order { $0.viewCount.asc() }.limit(limit).select { ($0.id, $0.title) }))
        }
    }

    section("Preload: batched (Hangar) vs. the N+1 it replaces")

    // 50 authors, 4 posts each — the shape where N+1 actually bites.
    for _ in 0..<50 {
        let extra = UUID()
        try await repo.insert(BenchAuthor(id: extra, name: "author-\(extra)"))
        for _ in 0..<4 {
            var post = sampleModel()
            post.authorID = extra
            try await repo.insert(post)
        }
    }

    try await measureAsync("preload 50 authors × 4 posts (2 queries)", iterations: 20) {
        blackHole(
            try await repo.all(BenchAuthor.where { $0.name != "bench" }.preload(\.posts)))
    }

    // The shape Hangar's design exists to prevent, measured for contrast:
    // one query per parent, so the per-query floor multiplies by N.
    try await measureAsync("naive per-parent fetch (1 + 50 queries)", iterations: 20) {
        let authors = try await repo.all(BenchAuthor.where { $0.name != "bench" })
        for author in authors {
            blackHole(try await repo.all(BenchPost.where { $0.authorID == author.id }))
        }
    }

    section("Streaming vs. materializing 1000 rows")

    try await measureAsync("all() — materialize 1000 rows", iterations: 50) {
        blackHole(try await repo.all(BenchPost.limit(1_000)))
    }

    try await measureAsync("stream() — decode 1000 rows lazily", iterations: 50) {
        try await repo.stream(BenchPost.limit(1_000)) { rows in
            var count = 0
            for try await row in rows { blackHole(row); count += 1 }
            blackHole(count)
        }
    }

    section("Prepared statements: what Hangar leaves on the table")

    // Hangar cannot reach PostgresNIO's named prepared statements (the
    // protocol needs `static let sql`, ours is built at runtime). This
    // measures the gap directly: identical SQL, one path re-parsed by the
    // server every execution, the other prepared once.
    let preparedSQL = BenchPost.where { $0.id == target.id }.debugSQL
    struct PreparedLookup: PostgresPreparedStatement {
        static var sql: String { preparedStatementSQL }
        typealias Row = UUID
        var id: UUID
        func makeBindings() throws -> PostgresBindings {
            var bindings = PostgresBindings()
            bindings.append(id)
            return bindings
        }
        func decodeRow(_ row: PostgresRow) throws -> Row {
            try row.makeRandomAccess()[0].decode(UUID.self)
        }
    }
    preparedStatementSQL = preparedSQL

    try await measureAsync("unnamed (what Hangar sends today)", iterations: 500) {
        blackHole(try await repo.one(BenchPost.where { $0.id == target.id }))
    }

    try await measureAsync("named prepared statement, same SQL", iterations: 500) {
        let rows = try await benchClient.execute(PreparedLookup(id: target.id), logger: nil)
        for try await row in rows { blackHole(row) }
        blackHole(rows)
    }

    section("Writes")

    try await measureAsync("INSERT ... RETURNING (11 columns)", iterations: 300) {
        blackHole(try await repo.insert(sampleModel()))
    }

    var mutable = target
    try await measureAsync("UPDATE whole row by key", iterations: 300) {
        mutable.viewCount &+= 1
        blackHole(try await repo.update(mutable))
    }

    try await measureAsync("UPDATE via changeset (1 dirty column)", iterations: 300) {
        blackHole(
            try await repo.update(Changeset(original: target).change(\.title, "changed \(UUID())")))
    }
}

// MARK: - Harness

let databaseURL = ProcessInfo.processInfo.environment["HANGAR_TEST_DATABASE_URL"]

print("Hangar benchmarks")
print("=================")
#if DEBUG
    print("\n⚠️  DEBUG build — these numbers measure the optimizer being off.")
    print("   Re-run with: swift run -c release hangar-bench\n")
#endif

try clientSideBenchmarks()

guard let databaseURL, let components = URLComponents(string: databaseURL) else {
    print("\nHANGAR_TEST_DATABASE_URL not set — skipping round-trip benchmarks.")
    exit(0)
}

let configuration = PostgresClient.Configuration(
    host: components.host ?? "127.0.0.1",
    port: components.port ?? 5432,
    username: components.user ?? "postgres",
    password: components.password,
    database: components.path.isEmpty ? nil : String(components.path.dropFirst()),
    tls: .disable)

let client = PostgresClient(configuration: configuration)
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }

    let schema = [
        #"DROP TABLE IF EXISTS "bench_posts""#,
        #"DROP TABLE IF EXISTS "bench_authors""#,
        #"DROP TYPE IF EXISTS "bench_status""#,
        #"CREATE TYPE "bench_status" AS ENUM ('draft', 'published')"#,
        #"""
        CREATE TABLE "bench_posts" (
            "id" uuid PRIMARY KEY,
            "title" text NOT NULL,
            "body" text NOT NULL,
            "published" boolean NOT NULL,
            "view_count" bigint NOT NULL,
            "rank" bigint NOT NULL,
            "created_at" timestamptz NOT NULL,
            "nickname" text,
            "status" bench_status NOT NULL,
            "metadata" jsonb NOT NULL,
            "author_id" uuid NOT NULL
        )
        """#,
        #"""
        CREATE TABLE "bench_authors" (
            "id" uuid PRIMARY KEY,
            "name" text NOT NULL
        )
        """#,
        #"CREATE INDEX ON "bench_posts" ("author_id")"#,
        #"CREATE INDEX ON "bench_posts" ("view_count")"#,
    ]
    for sql in schema {
        _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: nil)
    }

    benchClient = client
    try await roundTripBenchmarks(Repo(client: client))

    for sql in [#"DROP TABLE "bench_posts""#, #"DROP TABLE "bench_authors""#, #"DROP TYPE "bench_status""#] {
        _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: nil)
    }
    group.cancelAll()
}

print("")
