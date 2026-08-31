import Foundation
import Hangar
import PostgresNIO

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

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

// The join-comparison domain: JoinedQuery3 vs. ComposedQuery
// (Table.query { }) built and run over an identical schema and identical
// seed data, plus a 5-table query JoinedQuery3 cannot express at all
// (it caps at 3 tables) — see BENCHMARKS.md for the numbers this produces.

@Entity("bench_customers")
struct BenchCustomer: Sendable {
    @ID let id: UUID
    var name: String
    var active: Bool
}

@Entity("bench_orders")
struct BenchOrder: Sendable {
    @ID let id: UUID
    var customerID: UUID
}

@Entity("bench_order_items")
struct BenchOrderItem: Sendable {
    @ID let id: UUID
    var orderID: UUID
    var productID: UUID
    var quantity: Int
}

@Entity("bench_products")
struct BenchProduct: Sendable {
    @ID let id: UUID
    var name: String
    var categoryID: UUID
}

@Entity("bench_categories")
struct BenchCategory: Sendable {
    @ID let id: UUID
    var name: String
    var visible: Bool
}

struct BenchOrderReport: Decodable, Sendable {
    let orderID: UUID
    let customerName: String
    let productName: String
    let categoryName: String
    let quantity: Int
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

// MARK: - CPU/memory (JoinedQuery3 vs. ComposedQuery comparison only)
//
// `getrusage` is process-wide, not per-call — there is no OS primitive for
// "CPU time this one closure used" the way `ContinuousClock` gives wall
// time for free. Two things make a before/after snapshot around one tight
// loop meaningful anyway: this benchmark process does nothing concurrent
// (single task, no background work competing for the counters), and
// `ru_maxrss` is already a running high-water mark, so its delta answers a
// real question — "did this workload push the process's peak resident set
// higher" — even though it can never show memory that was allocated and
// freed again without raising the peak.

struct ResourceUsage {
    let userSeconds: Double
    let systemSeconds: Double
    let maxRSSKilobytes: Int
}

func snapshotResources() -> ResourceUsage {
    var usage = rusage()
    #if canImport(Glibc)
        getrusage(RUSAGE_SELF.rawValue, &usage)
    #else
        getrusage(RUSAGE_SELF, &usage)
    #endif
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    // Linux reports ru_maxrss in kilobytes already; Darwin reports bytes —
    // normalized to KB either way so the printed numbers mean the same
    // thing regardless of platform.
    #if canImport(Glibc)
        let maxRSSKB = usage.ru_maxrss
    #else
        let maxRSSKB = usage.ru_maxrss / 1024
    #endif
    return ResourceUsage(userSeconds: user, systemSeconds: system, maxRSSKilobytes: maxRSSKB)
}

/// Like `measure`, plus CPU time and peak-RSS deltas over the same
/// iterations — used only for the JoinedQuery3-vs-ComposedQuery
/// comparison below, where the whole point is measuring the builder's own
/// overhead, not just wall time.
@discardableResult
func measureWithResources(
    _ name: String, iterations: Int, warmup: Int = 100, _ body: () throws -> Void
) rethrows -> Duration {
    for _ in 0..<warmup { try body() }
    let before = snapshotResources()
    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        for _ in 0..<iterations { try body() }
    }
    let after = snapshotResources()
    report(name, elapsed / iterations, iterations: iterations)
    reportResources(before: before, after: after, iterations: iterations)
    return elapsed / iterations
}

@discardableResult
func measureAsyncWithResources(
    _ name: String, iterations: Int, warmup: Int = 5, _ body: () async throws -> Void
) async throws -> Duration {
    for _ in 0..<warmup { try await body() }
    let before = snapshotResources()
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0..<iterations { try await body() }
    let elapsed = clock.now - start
    let after = snapshotResources()
    report(name, elapsed / iterations, iterations: iterations)
    reportResources(before: before, after: after, iterations: iterations)
    return elapsed / iterations
}

func reportResources(before: ResourceUsage, after: ResourceUsage, iterations: Int) {
    let cpuDeltaSeconds = (after.userSeconds - before.userSeconds) + (after.systemSeconds - before.systemSeconds)
    let cpuPerIterMicros = (cpuDeltaSeconds / Double(iterations)) * 1_000_000
    let rssDeltaKB = after.maxRSSKilobytes - before.maxRSSKilobytes
    let cpuText = String(format: "%7.2f µs CPU/iter", cpuPerIterMicros)
    let rssText = rssDeltaKB > 0 ? "+\(rssDeltaKB) KB peak RSS over the run" : "no peak-RSS growth"
    print("  \(String(repeating: " ", count: 46)) \(cpuText)   (\(rssText))")
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

// MARK: - JoinedQuery3 vs. ComposedQuery (Table.query { })

/// The apples-to-apples 3-table join both APIs can express: order → customer,
/// order → item. Client-side only (render, no server) — the two APIs
/// produce the same SQL shape for Postgres to plan and run, so any
/// execution-time difference downstream would be noise; what's actually
/// comparable is the Swift-side cost of building and rendering the query
/// itself, which is what every iteration here pays before a byte reaches
/// the wire.
func joinComparisonClientSide() {
    section("JoinedQuery3 vs. ComposedQuery — equivalent 3-table join (render only)")

    measureWithResources("JoinedQuery3: order ⋈ customer ⋈ item", iterations: 100_000) {
        blackHole(
            BenchOrder.join(BenchCustomer.self, on: { order, customer in order.customerID == customer.id })
                .join(BenchOrderItem.self, on: { order, _, item in item.orderID == order.id })
                .debugSQL)
    }

    measureWithResources("ComposedQuery: order ⋈ customer ⋈ item", iterations: 100_000) {
        let query = BenchOrder.query { q, order in
            _ = q.join(BenchCustomer.self) { $0.id == order.customerID }
            _ = q.join(BenchOrderItem.self) { $0.orderID == order.id }
            return q.query()
        }
        blackHole(query.debugSQL)
    }

    section("...the same comparison, projected — the shape a real call site actually uses")

    measureWithResources("JoinedQuery3: same join, select(into:)", iterations: 100_000) {
        blackHole(
            BenchOrder.join(BenchCustomer.self, on: { order, customer in order.customerID == customer.id })
                .join(BenchOrderItem.self, on: { order, _, item in item.orderID == order.id })
                .select(into: BenchOrderItemRow.self) { order, customer, item in
                    (orderID: order.id, customerName: customer.name, quantity: item.quantity)
                }
                .debugSQL)
    }

    measureWithResources("ComposedQuery: same join, select(into:)", iterations: 100_000) {
        let query = BenchOrder.query { q, order in
            let customer = q.join(BenchCustomer.self) { $0.id == order.customerID }
            let item = q.join(BenchOrderItem.self) { $0.orderID == order.id }
            return q.select(into: BenchOrderItemRow.self) {
                (orderID: order.id, customerName: customer.name, quantity: item.quantity)
            }
        }
        blackHole(query.debugSQL)
    }

    section("The 5-table query JoinedQuery3 cannot express at all (caps at 3 tables)")
    print("  No comparison to print here — there is no JoinedQuery4/5 to run against.")
    print("  This is new capability, not a speed delta. Timed on its own for reference:")

    measureWithResources("ComposedQuery: order ⋈ customer ⋈ item ⋈ product ⋈ category", iterations: 100_000) {
        let query = BenchOrder.query { q, order in
            let customer = q.join(BenchCustomer.self) { $0.id == order.customerID }
            let item = q.join(BenchOrderItem.self) { $0.orderID == order.id }
            let product = q.join(BenchProduct.self) { $0.id == item.productID }
            let category = q.join(BenchCategory.self) { $0.id == product.categoryID }
            q.where(customer.active && category.visible)
            return q.select(into: BenchOrderReport.self) {
                (
                    orderID: order.id, customerName: customer.name, productName: product.name,
                    categoryName: category.name, quantity: item.quantity
                )
            }
        }
        blackHole(query.debugSQL)
    }
}

struct BenchOrderItemRow: Decodable, Sendable {
    let orderID: UUID
    let customerName: String
    let quantity: Int
}

/// Same comparison, executed against real rows — captures anything the
/// render-only comparison couldn't: decode cost, and whether the extra
/// alias qualification ComposedQuery always emits (`AS "t0"`, `AS "t1"`...,
/// even when nothing is ambiguous) changes Postgres's own planning time.
func joinComparisonRoundTrip(_ repo: Repo) async throws {
    section("JoinedQuery3 vs. ComposedQuery — same 3-table join, real Postgres")

    let customerID = seededCustomerID
    try await measureAsyncWithResources("JoinedQuery3: order ⋈ customer ⋈ item, real rows", iterations: 300) {
        blackHole(
            try await repo.all(
                BenchOrder.join(BenchCustomer.self, on: { order, customer in order.customerID == customer.id })
                    .join(BenchOrderItem.self, on: { order, _, item in item.orderID == order.id })
                    .where { order, _, _ in order.customerID == customerID }
                    .select(into: BenchOrderItemRow.self) { order, customer, item in
                        (orderID: order.id, customerName: customer.name, quantity: item.quantity)
                    }))
    }

    try await measureAsyncWithResources("ComposedQuery: order ⋈ customer ⋈ item, real rows", iterations: 300) {
        blackHole(
            try await repo.all(
                BenchOrder.query { q, order in
                    let customer = q.join(BenchCustomer.self) { $0.id == order.customerID }
                    let item = q.join(BenchOrderItem.self) { $0.orderID == order.id }
                    q.where(order.customerID == customerID)
                    return q.select(into: BenchOrderItemRow.self) {
                        (orderID: order.id, customerName: customer.name, quantity: item.quantity)
                    }
                }))
    }

    section("The 5-table query, executed for real — proof it isn't just a rendering trick")
    let reports = try await repo.all(
        BenchOrder.query { q, order in
            let customer = q.join(BenchCustomer.self) { $0.id == order.customerID }
            let item = q.join(BenchOrderItem.self) { $0.orderID == order.id }
            let product = q.join(BenchProduct.self) { $0.id == item.productID }
            let category = q.join(BenchCategory.self) { $0.id == product.categoryID }
            q.where(customer.active && category.visible)
            return q.select(into: BenchOrderReport.self) {
                (
                    orderID: order.id, customerName: customer.name, productName: product.name,
                    categoryName: category.name, quantity: item.quantity
                )
            }
        })
    print("  \(reports.count) real rows decoded (active customers, visible categories only)")
    if let sample = reports.first {
        print(
            "  sample: order \(sample.orderID) — \(sample.customerName) bought \(sample.quantity)× \(sample.productName) (\(sample.categoryName))"
        )
    }

    try await measureAsyncWithResources(
        "ComposedQuery: order ⋈ customer ⋈ item ⋈ product ⋈ category, real rows", iterations: 300
    ) {
        blackHole(
            try await repo.all(
                BenchOrder.query { q, order in
                    let customer = q.join(BenchCustomer.self) { $0.id == order.customerID }
                    let item = q.join(BenchOrderItem.self) { $0.orderID == order.id }
                    let product = q.join(BenchProduct.self) { $0.id == item.productID }
                    let category = q.join(BenchCategory.self) { $0.id == product.categoryID }
                    q.where(customer.active && category.visible)
                    return q.select(into: BenchOrderReport.self) {
                        (
                            orderID: order.id, customerName: customer.name, productName: product.name,
                            categoryName: category.name, quantity: item.quantity
                        )
                    }
                }))
    }
}

nonisolated(unsafe) var seededCustomerID = UUID()

/// 20 customers, 10 categories, 50 products, 100 orders, ~300 order items —
/// enough spread that the join actually does work, small enough that
/// seeding itself doesn't dominate the benchmark run. A fifth of customers
/// inactive and a fifth of categories hidden, so `q.where(customer.active
/// && category.visible)` in the 5-table query actually filters something.
func seedJoinComparisonFixture(_ repo: Repo) async throws {
    // Seeded through the batch insert, not 480 individual round trips —
    // outside the measured regions either way, but the shape this file's
    // own ~24× batch-insert number says to use, and it exercises the batch
    // path incidentally on every run.
    let customers = try await repo.insert(
        (0..<20).map { BenchCustomer(id: UUID(), name: "customer-\($0)", active: $0 % 5 != 0) })
    seededCustomerID = customers.first(where: \.active)!.id

    let categories = try await repo.insert(
        (0..<10).map { BenchCategory(id: UUID(), name: "category-\($0)", visible: $0 % 5 != 0) })

    let products = try await repo.insert(
        (0..<50).map { index in
            BenchProduct(
                id: UUID(), name: "product-\(index)",
                categoryID: categories[index % categories.count].id)
        })

    let orders = try await repo.insert(
        (0..<100).map { index in
            BenchOrder(id: UUID(), customerID: customers[index % customers.count].id)
        })

    _ = try await repo.insert(
        (0..<300).map { index in
            BenchOrderItem(
                id: UUID(), orderID: orders[index % orders.count].id,
                productID: products[index % products.count].id,
                quantity: 1 + (index % 5))
        })
}

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
joinComparisonClientSide()

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
        #"DROP TABLE IF EXISTS "bench_order_items""#,
        #"DROP TABLE IF EXISTS "bench_orders""#,
        #"DROP TABLE IF EXISTS "bench_products""#,
        #"DROP TABLE IF EXISTS "bench_categories""#,
        #"DROP TABLE IF EXISTS "bench_customers""#,
        #"""
        CREATE TABLE "bench_customers" (
            "id" uuid PRIMARY KEY,
            "name" text NOT NULL,
            "active" boolean NOT NULL
        )
        """#,
        #"""
        CREATE TABLE "bench_categories" (
            "id" uuid PRIMARY KEY,
            "name" text NOT NULL,
            "visible" boolean NOT NULL
        )
        """#,
        #"""
        CREATE TABLE "bench_products" (
            "id" uuid PRIMARY KEY,
            "name" text NOT NULL,
            "category_id" uuid NOT NULL REFERENCES "bench_categories"("id")
        )
        """#,
        #"""
        CREATE TABLE "bench_orders" (
            "id" uuid PRIMARY KEY,
            "customer_id" uuid NOT NULL REFERENCES "bench_customers"("id")
        )
        """#,
        #"""
        CREATE TABLE "bench_order_items" (
            "id" uuid PRIMARY KEY,
            "order_id" uuid NOT NULL REFERENCES "bench_orders"("id"),
            "product_id" uuid NOT NULL REFERENCES "bench_products"("id"),
            "quantity" bigint NOT NULL
        )
        """#,
        #"CREATE INDEX ON "bench_orders" ("customer_id")"#,
        #"CREATE INDEX ON "bench_order_items" ("order_id")"#,
        #"CREATE INDEX ON "bench_order_items" ("product_id")"#,
        #"CREATE INDEX ON "bench_products" ("category_id")"#,
    ]
    for sql in schema {
        _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: nil)
    }

    benchClient = client
    let repo = Repo(client: client)
    try await roundTripBenchmarks(repo)
    try await seedJoinComparisonFixture(repo)
    try await joinComparisonRoundTrip(repo)

    for sql in [
        #"DROP TABLE "bench_order_items""#, #"DROP TABLE "bench_orders""#,
        #"DROP TABLE "bench_products""#, #"DROP TABLE "bench_categories""#,
        #"DROP TABLE "bench_customers""#,
        #"DROP TABLE "bench_posts""#, #"DROP TABLE "bench_authors""#, #"DROP TYPE "bench_status""#,
    ] {
        _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: nil)
    }
    group.cancelAll()
}

print("")
