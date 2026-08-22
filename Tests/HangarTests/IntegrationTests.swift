import Foundation
import Testing

import Hangar

// The §12 pre-Phase-1 vertical slice, grown into the Phase-1 acceptance
// suite: macro → AST → renderer → PostgresNIO → decoder, against a real
// server. Serialized: the tests share fixture tables.

extension PostgresIntegrationSuite {
@Suite(
    "Phase 1 end-to-end (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct IntegrationTests {

    // MARK: The vertical slice

    @Test("insert → select where → decode round-trips a full row")
    func verticalSlice() async throws {
        try await withRepo { repo in
            let alice = Post.sample(title: "Alice's post", nickname: "al")
            try await repo.insert(alice)
            _ = try await repo.insert(Post.sample(title: "Unpublished", published: false))

            let found = try await repo.all(Post.where { $0.published == true })
            #expect(found == [alice])
        }
    }

    @Test("compound where + order + limit + offset")
    func compoundQuery() async throws {
        try await withRepo { repo in
            for count in 1...5 {
                _ = try await repo.insert(
                    Post.sample(title: "post-\(count)", viewCount: count * 10))
            }
            let page = try await repo.all(
                Post.where { $0.published && $0.viewCount >= 20 }
                    .order { $0.viewCount.desc() }
                    .limit(2)
                    .offset(1))
            #expect(page.map(\.title) == ["post-4", "post-3"])
        }
    }

    @Test("enum, jsonb, and optional columns round-trip; nil renders IS NULL")
    func dialectRoundTrips() async throws {
        try await withRepo { repo in
            let draft = Post.sample(title: "draft", published: false, status: .draft)
            try await repo.insert(draft)
            try await repo.insert(Post.sample(title: "named", nickname: "zed"))

            let drafts = try await repo.all(Post.where { $0.status == .draft })
            #expect(drafts.map(\.title) == ["draft"])
            #expect(drafts.first?.metadata == PostMetadata(tags: ["swift", "postgres"], readingMinutes: 7))

            let anonymous = try await repo.all(Post.where { $0.nickname == nil })
            #expect(anonymous.map(\.title) == ["draft"])
            let named = try await repo.all(Post.where { $0.nickname == "zed" })
            #expect(named.map(\.title) == ["named"])
        }
    }

    @Test("ilike uses a bound pattern")
    func ilike() async throws {
        try await withRepo { repo in
            try await repo.insert(Post.sample(title: "Hangar Ships"))
            try await repo.insert(Post.sample(title: "unrelated"))
            let hits = try await repo.all(Post.where { $0.title.ilike("%hangar%") })
            #expect(hits.map(\.title) == ["Hangar Ships"])
        }
    }

    // MARK: one / count / exists

    @Test("one returns nil, the row, or throws on ambiguity")
    func one() async throws {
        try await withRepo { repo in
            #expect(try await repo.one(Post.where { $0.published }) == nil)

            let post = Post.sample()
            try await repo.insert(post)
            #expect(try await repo.one(Post.where { $0.id == post.id }) == post)

            try await repo.insert(Post.sample(title: "second"))
            await #expect(throws: HangarError.self) {
                _ = try await repo.one(Post.where { $0.published })
            }
        }
    }

    @Test("count and exists")
    func countAndExists() async throws {
        try await withRepo { repo in
            #expect(try await repo.count(Post.all) == 0)
            #expect(try await repo.exists(Post.all) == false)
            try await repo.insert(Post.sample(viewCount: 5))
            try await repo.insert(Post.sample(viewCount: 50))
            #expect(try await repo.count(Post.all) == 2)
            #expect(try await repo.count(Post.where { $0.viewCount > 10 }) == 1)
            #expect(try await repo.exists(Post.where { $0.viewCount > 10 }))
        }
    }

    // MARK: Writes

    @Test("update writes non-key columns and returns the stored row")
    func update() async throws {
        try await withRepo { repo in
            var post = Post.sample(title: "before")
            try await repo.insert(post)
            post.title = "after"
            post.viewCount = 99
            let stored = try await repo.update(post)
            #expect(stored.title == "after")
            #expect(try await repo.all(Post.all).map(\.title) == ["after"])
            #expect(try await repo.all(Post.all).map(\.viewCount) == [99])
        }
    }

    @Test("update and delete on a vanished row throw staleModel, not silence")
    func staleModel() async throws {
        try await withRepo { repo in
            let post = Post.sample()
            try await repo.insert(post)
            try await repo.delete(post)

            await #expect(throws: HangarError.self) { try await repo.delete(post) }
            await #expect(throws: HangarError.self) { _ = try await repo.update(post) }
            #expect(try await repo.count(Post.all) == 0)
        }
    }

    @Test("database-generated keys come back via RETURNING")
    func generatedKey() async throws {
        try await withRepo { repo in
            let first = try await repo.insert(Event(name: "first"))
            let second = try await repo.insert(Event(name: "second"))
            #expect(first.id > 0)
            #expect(second.id > first.id)

            let fetched = try await repo.all(Event.where { $0.name == "second" })
            #expect(fetched == [second])
        }
    }

    // MARK: Ambient repo (design §5.1)

    @Test("Repo.with binds the task-local; absence throws a named error")
    func ambientRepo() async throws {
        try await withRepo { repo in
            try await repo.insert(Post.sample())
            let count = try await Repo.with(repo) {
                try await Repo.require().count(Post.all)
            }
            #expect(count == 1)

            #expect(throws: HangarError.self) { _ = try Repo.require() }
        }
    }
}
}
