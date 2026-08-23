import Foundation
import Testing

@testable import Hangar

// Phase 4: joins and correlated subqueries — the
// multi-table scopes where every column renders table-qualified.

@Suite("Joins and correlated subqueries — SQL")
struct JoinRendererTests {

    @Test("inner join selects the base entity's columns, qualified")
    func joinBase() throws {
        let statement = try SQLRenderer.select(
            Post.join(Comment.self, on: { p, c in c.postID == p.id }))
        #expect(statement.sql == #"SELECT "hangar_posts"."id", "hangar_posts"."title", "hangar_posts"."published", "hangar_posts"."view_count", "hangar_posts"."created_at", "hangar_posts"."nickname", "hangar_posts"."status", "hangar_posts"."metadata", "hangar_posts"."author_id" FROM "hangar_posts" JOIN "hangar_comments" ON ("hangar_comments"."post_id" = "hangar_posts"."id")"#)
    }

    @Test("leftJoin + groupBy + select(into:) with an aggregate")
    func designExample() throws {
        struct PostSummary: Decodable, Sendable {
            let id: UUID
            let title: String
            let commentCount: Int
        }
        let statement = try SQLRenderer.select(
            Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
                .groupBy { p, _ in p.id }
                .groupBy { p, _ in p.title }
                .select(into: PostSummary.self) { p, c in
                    (id: p.id, title: p.title, commentCount: c.id.count())
                })
        #expect(statement.sql == #"SELECT "hangar_posts"."id" AS "id", "hangar_posts"."title" AS "title", count("hangar_comments"."id") AS "commentCount" FROM "hangar_posts" LEFT JOIN "hangar_comments" ON ("hangar_comments"."post_id" = "hangar_posts"."id") GROUP BY "hangar_posts"."id", "hangar_posts"."title""#)
    }

    @Test("a composed single-table query carries its clauses into the join")
    func composedIntoJoin() throws {
        let statement = try SQLRenderer.select(
            Post.where { $0.published }
                .limit(5)
                .join(Comment.self, on: { p, c in c.postID == p.id })
                .where { _, c in c.body != "" })
        #expect(statement.sql.contains(#"ON ("hangar_comments"."post_id" = "hangar_posts"."id")"#))
        #expect(statement.sql.contains(#"WHERE ("hangar_posts"."published" AND ("hangar_comments"."body" <> $1))"#))
        #expect(statement.sql.hasSuffix("LIMIT 5"))
    }

    @Test("correlated EXISTS qualifies inner and outer columns")
    func correlatedExists() {
        let statement = SQLRenderer.select(
            Post.where { p in
                Comment.where { $0.postID == p.id && $0.body != "" }.exists()
            })
        #expect(statement.sql.hasSuffix(#"WHERE EXISTS (SELECT 1 FROM "hangar_comments" WHERE (("hangar_comments"."post_id" = "hangar_posts"."id") AND ("hangar_comments"."body" <> $1)))"#))
        #expect(statement.binds.count == 1)
    }

    @Test("self-joins are refused until aliases exist")
    func selfJoin() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.select(Post.join(Post.self, on: { a, b in a.id == b.id }))
        }
    }
}

extension PostgresIntegrationSuite {
@Suite(
    "Joins (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct JoinIntegrationTests {

    @Test("inner join filters base rows; distinct collapses fan-out")
    func innerJoin() async throws {
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let commented = try await repo.insert(Post.sample(title: "commented"))
            _ = try await repo.insert(Post.sample(title: "silent"))
            for body in ["one", "two"] {
                try await repo.insert(
                    Comment(id: UUID(), postID: commented.id, authorID: author.id, body: body))
            }

            let joined = Post.join(Comment.self, on: { p, c in c.postID == p.id })
            // Two comments → the base row fans out twice…
            let fanned = try await repo.all(joined)
            #expect(fanned.map(\.title) == ["commented", "commented"])
            #expect(try await repo.count(joined) == 2)
            // …and DISTINCT collapses it.
            let collapsed = try await repo.all(joined.distinct())
            #expect(collapsed.map(\.title) == ["commented"])
        }
    }

    @Test("end-to-end: comment counts per post, zero included")
    func postSummaries() async throws {
        struct PostSummary: Decodable, Sendable, Equatable {
            let title: String
            let commentCount: Int
        }
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let busy = try await repo.insert(Post.sample(title: "busy"))
            _ = try await repo.insert(Post.sample(title: "quiet"))
            for body in ["a", "b", "c"] {
                try await repo.insert(
                    Comment(id: UUID(), postID: busy.id, authorID: author.id, body: body))
            }

            let summaries = try await repo.all(
                Post.leftJoin(Comment.self, on: { p, c in c.postID == p.id })
                    .groupBy { p, _ in p.id }
                    .groupBy { p, _ in p.title }
                    .order { p, _ in p.title.asc() }
                    .select(into: PostSummary.self) { p, c in
                        (title: p.title, commentCount: c.id.count())
                    })
            #expect(summaries == [
                PostSummary(title: "busy", commentCount: 3),
                PostSummary(title: "quiet", commentCount: 0),
            ])
        }
    }

    @Test("joined pack projection mixes both tables' columns")
    func joinedPackSelect() async throws {
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let post = try await repo.insert(Post.sample(title: "threaded"))
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: author.id, body: "hello"))

            let rows: [(String, String)] = try await repo.all(
                Post.join(Comment.self, on: { p, c in c.postID == p.id })
                    .select { p, c in (p.title, c.body) })
            #expect(rows.count == 1)
            #expect(rows[0] == ("threaded", "hello"))
        }
    }

    @Test("correlated EXISTS: posts that have a matching comment")
    func correlatedExists() async throws {
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "ada"))
            let noisy = try await repo.insert(Post.sample(title: "noisy"))
            _ = try await repo.insert(Post.sample(title: "silent"))
            try await repo.insert(
                Comment(id: UUID(), postID: noisy.id, authorID: author.id, body: "hi"))

            let posts = try await repo.all(
                Post.where { p in
                    Comment.where { $0.postID == p.id }.exists()
                })
            #expect(posts.map(\.title) == ["noisy"])

            // Negated: posts with no comments.
            let silent = try await repo.all(
                Post.where { p in
                    !Comment.where { $0.postID == p.id }.exists()
                })
            #expect(silent.map(\.title) == ["silent"])
        }
    }

    @Test("preloads carry through a join on the base-entity path")
    func joinWithPreload() async throws {
        try await withRepo { repo in
            let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
            var post = Post.sample(title: "authored")
            post.authorID = ada.id
            try await repo.insert(post)
            try await repo.insert(
                Comment(id: UUID(), postID: post.id, authorID: ada.id, body: "hi"))

            let posts = try await repo.all(
                Post.all.preload(\.author)
                    .join(Comment.self, on: { p, c in c.postID == p.id }))
            #expect(try posts.map { try $0.author.get().name } == ["ada"])
        }
    }
}
}
