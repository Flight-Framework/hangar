import Foundation
import Testing

@testable import Hangar

/// Common table expressions.
///
/// The rendering contract is the interesting half: a CTE has to appear
/// before the SELECT it feeds, its binds have to be numbered in *text*
/// order rather than the order the builder methods were called, and a query
/// reading from a CTE has to alias it back to the entity's table name so
/// every column qualification downstream still resolves.
@Suite("CTE rendering")
struct CTERendererTests {

    @Test("a named subquery renders before the select it feeds")
    func withClauseComesFirst() {
        let statement = SQLRenderer.select(
            Post.all
                .with("recent", as: Post.where { $0.published == true })
                .reading(from: "recent"))

        #expect(statement.sql.hasPrefix(#"WITH "recent" AS (SELECT "#))
        #expect(statement.sql.contains(#"FROM "recent" AS "hangar_posts""#))
    }

    @Test("without reading(from:), the CTE is defined but the FROM is the real table")
    func defineWithoutReading() {
        let statement = SQLRenderer.select(
            Post.all.with("recent", as: Post.where { $0.published == true }))

        #expect(statement.sql.contains(#"WITH "recent" AS"#))
        #expect(statement.sql.contains(#"FROM "hangar_posts""#))
        #expect(!statement.sql.contains(#"AS "hangar_posts""#))
    }

    @Test("binds are numbered in text order, not builder order")
    func bindOrder() {
        // The predicate is written first and the CTE second, but the CTE
        // renders first — so the CTE's bind must be $1.
        let statement = SQLRenderer.select(
            Post.where { $0.viewCount > 100 }
                .with("popular", as: Post.where { $0.viewCount > 500 }))

        // The CTE body closes, then the outer SELECT begins: $1 must fall
        // on the CTE's side of that boundary and $2 on the outer side.
        let boundary = statement.sql.range(of: ") SELECT ")!
        #expect(statement.sql.range(of: "$1")!.lowerBound < boundary.lowerBound)
        #expect(statement.sql.range(of: "$2")!.lowerBound > boundary.upperBound)
        #expect(statement.binds.count == 2)
    }

    @Test("several CTEs render in the order they were added")
    func ordered() {
        let statement = SQLRenderer.select(
            Post.all
                .with("a", as: Post.where { $0.published == true })
                .with("b", as: SQLFragment(#"SELECT * FROM "a""#))
                .reading(from: "b"))

        let a = statement.sql.range(of: #""a" AS"#)!
        let b = statement.sql.range(of: #""b" AS"#)!
        #expect(a.lowerBound < b.lowerBound)
        #expect(statement.sql.hasPrefix("WITH \"a\" AS"))
    }

    @Test("one recursive member makes the whole WITH list recursive, once")
    func recursiveKeyword() {
        let statement = SQLRenderer.select(
            Post.all
                .with("plain", as: Post.all)
                .withRecursive("tree", anchor: Post.where { $0.published == true },
                               recursive: SQLFragment(#"SELECT * FROM "tree""#))
                .reading(from: "tree"))

        #expect(statement.sql.hasPrefix("WITH RECURSIVE "))
        #expect(statement.sql.components(separatedBy: "RECURSIVE").count == 2)
    }

    @Test("a recursive body is anchor UNION ALL step")
    func recursiveShape() {
        let statement = SQLRenderer.select(
            Node.all
                .withRecursive(
                    "subtree",
                    anchor: Node.where { $0.parentID == nil },
                    recursive: SQLFragment(
                        #"SELECT "hangar_nodes".* FROM "hangar_nodes" JOIN "subtree" ON "hangar_nodes"."parent_id" = "subtree"."id""#
                    ))
                .reading(from: "subtree"))

        #expect(statement.sql.contains("UNION ALL"))
        #expect(statement.sql.contains(#"FROM "subtree" AS "hangar_nodes""#))
    }

    @Test("a raw CTE body's interpolations become binds, not text")
    func rawBodyBinds() {
        let cutoff = 42
        let statement = SQLRenderer.select(
            Post.all
                .with("busy", as: "SELECT * FROM \"hangar_posts\" WHERE \"view_count\" > \(cutoff)")
                .reading(from: "busy"))

        #expect(statement.binds.count == 1)
        #expect(!statement.sql.contains("42"))
        #expect(statement.sql.contains("$1"))
    }

    @Test("count and exists carry the CTE too")
    func countAndExists() {
        let query = Post.all
            .with("recent", as: Post.where { $0.published == true })
            .reading(from: "recent")

        #expect(SQLRenderer.count(query).sql.hasPrefix(#"WITH "recent" AS"#))
        #expect(SQLRenderer.count(query).sql.contains(#"FROM "recent" AS "hangar_posts""#))
        #expect(SQLRenderer.exists(query).sql.hasPrefix(#"WITH "recent" AS"#))
    }

    @Test("a bulk write may be fed by a CTE but not target one")
    func bulkWriteRules() throws {
        let fed = Post.where { $0.published == false }
            .with("stale", as: Post.where { $0.viewCount == 0 })
        #expect(try SQLRenderer.delete(fed).sql.hasPrefix(#"WITH "stale" AS"#))

        let targeted = fed.reading(from: "stale")
        #expect(throws: HangarError.self) { _ = try SQLRenderer.delete(targeted) }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.update(targeted, set: [])
        }
    }

    @Test("a query with no CTEs renders exactly as before")
    func noCTEIsUnchanged() {
        let statement = SQLRenderer.select(Post.where { $0.published == true })
        #expect(!statement.sql.contains("WITH"))
        #expect(statement.sql.contains(#"FROM "hangar_posts" WHERE"#))
    }

    @Test("a projection keeps the CTE it was given")
    func projectionCarriesTheCTE() {
        let statement = SQLRenderer.select(
            StoredFile.all
                .with("all_files", as: StoredFile.all.withDeleted())
                .reading(from: "all_files")
                .select { ($0.name, $0.sizeBytes) })

        // Both halves: the definition, and the FROM that reads it. Checking
        // only the FROM would pass with the CTE silently dropped, producing
        // SQL that names a relation nothing defines.
        #expect(statement.sql.hasPrefix(#"WITH "all_files" AS (SELECT "#))
        #expect(statement.sql.contains(#"FROM "all_files" AS "hangar_files""#))
    }

    /// The regression this pins: `rebinding` — the projection pivot — used
    /// to drop `deletedRows`, so `.withDeleted().select {}` quietly went
    /// back to hiding deleted rows. A projection answering a different
    /// question than the query it came from is the exact failure mode this
    /// codebase refuses to ship.
    @Test("a projection keeps the soft-delete scope it was given")
    func projectionCarriesDeletedScope() {
        let filtered = SQLRenderer.select(StoredFile.all.select { ($0.name, $0.sizeBytes) })
        #expect(filtered.sql.contains(#""deleted_at" IS NULL"#), "the default still hides them")

        let unfiltered = SQLRenderer.select(
            StoredFile.all.withDeleted().select { ($0.name, $0.sizeBytes) })
        #expect(!unfiltered.sql.contains("IS NULL"))

        let onlyGone = SQLRenderer.select(
            StoredFile.all.onlyDeleted().select { ($0.name, $0.sizeBytes) })
        #expect(onlyGone.sql.contains(#""deleted_at" IS NOT NULL"#))
    }
}

@Suite(
    "CTE — against Postgres", .serialized,
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct CTEIntegrationTests {

    /// root → a → a1, and a detached sibling that must not appear.
    private func seedTree(_ repo: Repo) async throws -> Node {
        let root = try await repo.insert(Node(id: UUID(), name: "root", parentID: nil))
        let a = try await repo.insert(Node(id: UUID(), name: "a", parentID: root.id))
        _ = try await repo.insert(Node(id: UUID(), name: "a1", parentID: a.id))
        _ = try await repo.insert(Node(id: UUID(), name: "elsewhere", parentID: nil))
        return root
    }

    @Test("a recursive CTE walks a tree of unbounded depth")
    func recursiveWalk() async throws {
        try await withRepo { repo in
            let root = try await seedTree(repo)
            let subtree = Node.all
                .withRecursive(
                    "subtree",
                    anchor: Node.where { $0.id == root.id },
                    recursive: """
                        SELECT "hangar_nodes".* FROM "hangar_nodes" \
                        JOIN "subtree" ON "hangar_nodes"."parent_id" = "subtree"."id"
                        """)
                .reading(from: "subtree")
                .order { $0.name.asc() }

            let found = try await repo.all(subtree)
            #expect(found.map(\.name) == ["a", "a1", "root"])
        }
    }

    @Test("a non-recursive CTE feeds a predicate, with real binds")
    func nonRecursive() async throws {
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "A"))
            for (title, views) in [("hot", 900), ("warm", 100), ("cold", 1)] {
                _ = try await repo.insert(
                    Post(
                        id: UUID(), title: title, published: true, viewCount: views,
                        createdAt: Date(), nickname: nil, status: .published,
                        metadata: PostMetadata(tags: [], readingMinutes: 1),
                        authorID: author.id))
            }

            let query = Post.all
                .with("busy", as: Post.where { $0.viewCount > 50 })
                .reading(from: "busy")
                .order { $0.title.asc() }

            #expect(try await repo.all(query).map(\.title) == ["hot", "warm"])
            #expect(try await repo.count(query) == 2)
            #expect(try await repo.exists(query))
        }
    }

    @Test("a CTE feeds a bulk delete")
    func cteFedDelete() async throws {
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "A"))
            for (title, views) in [("keep", 900), ("drop", 1)] {
                _ = try await repo.insert(
                    Post(
                        id: UUID(), title: title, published: true, viewCount: views,
                        createdAt: Date(), nickname: nil, status: .published,
                        metadata: PostMetadata(tags: [], readingMinutes: 1),
                        authorID: author.id))
            }

            let deleted = try await repo.delete(
                Post.all
                    .with("doomed", as: Post.where { $0.viewCount < 10 })
                    .where { _ in
                        SQLFragment(#""hangar_posts"."id" IN (SELECT "id" FROM "doomed")"#)
                    })

            #expect(deleted == 1)
            #expect(try await repo.all(Post.all).map(\.title) == ["keep"])
        }
    }
}
