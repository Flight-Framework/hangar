import Foundation
import Testing

import Hangar

// Streaming (`repo.stream`) and the schema precomputation behind it — the
// performance pass's user-visible surface.

@Suite("Precomputed schema metadata stays consistent with the columns")
struct SchemaPrecomputationTests {

    @Test("derived subsets match what filtering the columns would produce")
    func derivedSubsets() {
        #expect(Post.schema.primaryKey.map(\.name) == Post.schema.columns.filter(\.isPrimaryKey).map(\.name))
        #expect(Post.schema.insertable.map(\.name) == Post.schema.columns.filter { !$0.isGenerated }.map(\.name))
        #expect(Event.schema.insertable.map(\.name) == ["name"])
        #expect(Event.schema.updatable.map(\.name) == ["name"])
    }

    @Test("identifier quoting still escapes embedded quotes (the slow path)")
    func quotingEscapes() {
        #expect(SQLRenderer_quoteForTest("plain") == #""plain""#)
        #expect(SQLRenderer_quoteForTest(#"we"ird"#) == #""we""ird""#)
        #expect(SQLRenderer_quoteForTest(#"""#) == #""""""#)
    }

    @Test("debugSQL exposes the statement without interpolating values")
    func debugSQL() {
        let sql = Post.where { $0.title == "secret" }.debugSQL
        #expect(sql.contains("$1"))
        #expect(!sql.contains("secret"))
    }
}

extension PostgresIntegrationSuite {
@Suite(
    "Streaming (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct StreamingIntegrationTests {

    @Test("stream decodes every row, in order, without materializing")
    func streamFullModels() async throws {
        try await withRepo { repo in
            for index in 1...25 {
                try await repo.insert(Post.sample(title: "post-\(index)", viewCount: index))
            }
            let titles = try await repo.stream(Post.order { $0.viewCount.asc() }) { rows in
                var collected: [String] = []
                for try await post in rows { collected.append(post.title) }
                return collected
            }
            #expect(titles.count == 25)
            #expect(titles.first == "post-1")
            #expect(titles.last == "post-25")
        }
    }

    @Test("stream works over a projection too")
    func streamProjection() async throws {
        try await withRepo { repo in
            try await repo.insert(Post.sample(title: "only", viewCount: 7))
            let rows = try await repo.stream(Post.select { ($0.title, $0.viewCount) }) { rows in
                var collected: [(String, Int)] = []
                for try await row in rows { collected.append(row) }
                return collected
            }
            #expect(rows.count == 1)
            #expect(rows[0] == ("only", 7))
        }
    }

    @Test("an early break stops consuming and still releases the connection")
    func earlyBreak() async throws {
        try await withRepo { repo in
            for index in 1...50 {
                try await repo.insert(Post.sample(title: "p\(index)", viewCount: index))
            }
            let first: String? = try await repo.stream(Post.order { $0.viewCount.asc() }) { rows in
                for try await post in rows { return post.title }
                return nil
            }
            #expect(first == "p1")
            // The connection came back to the pool: a following query works.
            let count = try await repo.count(Post.all)
            #expect(count == 50)
        }
    }

    @Test("streaming an empty result set yields nothing")
    func streamEmpty() async throws {
        try await withRepo { repo in
            let count = try await repo.stream(Post.where { $0.title == "nothing" }) { rows in
                var seen = 0
                for try await _ in rows { seen += 1 }
                return seen
            }
            #expect(count == 0)
        }
    }

    @Test("a duplicate related key no longer traps the process (§7.3)")
    func duplicateRelatedKeyDoesNotTrap() async throws {
        try await withRepo { repo in
            // Two profiles for one author: @HasOne over a non-unique column
            // is a user modelling mistake. It must resolve to one row, not
            // kill the node — the trap this replaced would have.
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            try await repo.insert(Profile(id: UUID(), authorID: author.id, bio: "first"))
            try await repo.insert(Profile(id: UUID(), authorID: author.id, bio: "second"))

            let authors = try await repo.all(Author.all.preload(\.profile))
            let bio = try #require(try authors.first?.profile.get()?.bio)
            #expect(["first", "second"].contains(bio))
        }
    }
}
}
