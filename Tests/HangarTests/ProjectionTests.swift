import Foundation
import Testing

@testable import Hangar

// Phase 4 (design §6, §8): projections, aggregates, subqueries, upsert.
// The unit suite pins SQL text; the integration suite proves decode.

@Suite("Projections and aggregates — SQL (design §6)")
struct ProjectionRendererTests {

    @Test("select single column — the §6.3 pack signature at arity 1")
    func selectSingle() {
        let statement = SQLRenderer.select(Post.select { $0.id })
        #expect(statement.sql == #"SELECT "id" FROM "hangar_posts""#)
    }

    @Test("select tuple keeps written order and composes with where")
    func selectTuple() {
        let statement = SQLRenderer.select(
            Post.where { $0.published }.select { ($0.id, $0.title, $0.viewCount) })
        #expect(statement.sql == #"SELECT "id", "title", "view_count" FROM "hangar_posts" WHERE "published""#)
    }

    @Test("aggregates render with their dialect casts (NUMERIC never reaches the decoder)")
    func aggregateCasts() {
        let statement = SQLRenderer.select(
            Post.select { ($0.id.count(), $0.viewCount.sum(), $0.viewCount.avg(), $0.createdAt.max()) })
        #expect(statement.sql == #"SELECT count("id"), (sum("view_count"))::bigint, (avg("view_count"))::float8, max("created_at") FROM "hangar_posts""#)
    }

    @Test("groupBy + having render after WHERE, with bound aggregate comparisons")
    func groupByHaving() {
        let statement = SQLRenderer.select(
            Post.where { $0.published }
                .groupBy { $0.authorID }
                .having { $0.viewCount.sum() > 100 }
                .select { ($0.authorID, $0.id.count()) })
        #expect(statement.sql == #"SELECT "author_id", count("id") FROM "hangar_posts" WHERE "published" GROUP BY "author_id" HAVING ((sum("view_count"))::bigint > $1)"#)
        #expect(statement.binds.count == 1)
    }

    @Test("select(into:) aliases every column from the tuple labels")
    func selectIntoAliases() {
        struct AuthorCount: Decodable, Sendable {
            let author: UUID
            let posts: Int
        }
        let statement = SQLRenderer.select(
            Post.groupBy { $0.authorID }
                .select(into: AuthorCount.self) { (author: $0.authorID, posts: $0.id.count()) })
        #expect(statement.sql == #"SELECT "author_id" AS "author", count("id") AS "posts" FROM "hangar_posts" GROUP BY "author_id""#)
    }

    @Test("a select(into:) tuple without labels is refused before the wire")
    func selectIntoUnlabeled() async {
        struct Pair: Decodable, Sendable {
            let a: UUID
            let b: String
        }
        let query = Post.select(into: Pair.self) { ($0.id, $0.title) }
        #expect(query.selection?.invalid != nil)
    }

    @Test("distinct")
    func distinct() {
        let statement = SQLRenderer.select(Post.select { $0.authorID }.distinct())
        #expect(statement.sql == #"SELECT DISTINCT "author_id" FROM "hangar_posts""#)
    }

    @Test("IN over a value list is one bound array")
    func inValues() {
        let statement = SQLRenderer.select(Post.where { $0.viewCount.in([1, 2, 3]) })
        #expect(statement.sql.hasSuffix(#"WHERE ("view_count" = ANY($1))"#))
        #expect(statement.binds.count == 1)
    }

    @Test("IN over a subquery shares the outer statement's placeholder numbering")
    func inSubquery() {
        let famous = Author.where { $0.name != "nobody" }.select { $0.id }
        let statement = SQLRenderer.select(
            Post.where { $0.published && $0.authorID.in(famous) && $0.viewCount > 10 })
        #expect(statement.sql == #"SELECT "id", "title", "published", "view_count", "created_at", "nickname", "status", "metadata", "author_id" FROM "hangar_posts" WHERE (("published" AND ("author_id" IN (SELECT "id" FROM "hangar_authors" WHERE ("name" <> $1)))) AND ("view_count" > $2))"#)
        #expect(statement.binds.count == 2)
    }
}

@Suite("Upsert — ON CONFLICT (design §6.2)")
struct UpsertRendererTests {

    @Test("doUpdate renders target and EXCLUDED assignments")
    func doUpdate() throws {
        let changeset = Changeset(KV.self).change(\.key, "k").change(\.value, "v")
        let statement = try SQLRenderer.insert(
            try changeset.validatedChanges(), into: KV.self,
            onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
        #expect(statement.sql == """
            INSERT INTO "hangar_kv" ("key", "value") VALUES ($1, $2) \
            ON CONFLICT ("key") DO UPDATE SET "value" = EXCLUDED."value" \
            RETURNING "id", "key", "value"
            """)
    }

    @Test("doNothing renders bare and targeted forms")
    func doNothing() throws {
        let changeset = Changeset(KV.self).change(\.key, "k").change(\.value, "v")
        let bare = try SQLRenderer.insert(
            try changeset.validatedChanges(), into: KV.self, onConflict: .doNothing)
        #expect(bare.sql.contains("ON CONFLICT DO NOTHING"))
        let targeted = try SQLRenderer.insert(
            try changeset.validatedChanges(), into: KV.self,
            onConflict: .doNothing(target: [\KV.key]))
        #expect(targeted.sql.contains(#"ON CONFLICT ("key") DO NOTHING"#))
    }

    @Test("a non-column keypath in the conflict clause throws")
    func badKeyPath() throws {
        let changeset = Changeset(KV.self).change(\.key, "k")
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.insert(
                try changeset.validatedChanges(), into: KV.self,
                onConflict: .doUpdate(target: [\KV.self], set: [\KV.value]))
        }
    }
}

extension PostgresIntegrationSuite {
@Suite(
    "Projections, aggregates, upsert (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct ProjectionIntegrationTests {

    @Test("single-column and tuple projections decode typed")
    func typedProjections() async throws {
        try await withRepo { repo in
            let post = try await repo.insert(Post.sample(title: "projected", viewCount: 7))
            _ = try await repo.insert(Post.sample(title: "other", published: false, viewCount: 3))

            let ids: [UUID] = try await repo.all(Post.where { $0.published }.select { $0.id })
            #expect(ids == [post.id])

            let rows: [(UUID, String, Int)] = try await repo.all(
                Post.order { $0.viewCount.desc() }.select { ($0.id, $0.title, $0.viewCount) })
            #expect(rows.map(\.1) == ["projected", "other"])
            #expect(rows.map(\.2) == [7, 3])

            let pair = try await repo.one(Post.where { $0.title == "projected" }.select { ($0.title, $0.nickname) })
            #expect(pair?.0 == "projected")
            #expect(pair?.1 == nil)
        }
    }

    @Test("aggregates: count/sum/avg/min/max, with groupBy and having")
    func aggregates() async throws {
        try await withRepo { repo in
            let prolific = UUID()
            let quiet = UUID()
            for (author, views) in [(prolific, 10), (prolific, 30), (quiet, 5)] {
                var post = Post.sample(title: "v\(views)", viewCount: views)
                post.authorID = author
                try await repo.insert(post)
            }

            let totals = try await repo.all(
                Post.groupBy { $0.authorID }
                    .having { $0.viewCount.sum() > 20 }
                    .select { ($0.authorID, $0.id.count(), $0.viewCount.sum(), $0.viewCount.avg()) })
            #expect(totals.count == 1)
            #expect(totals[0].0 == prolific)
            #expect(totals[0].1 == 2)
            #expect(totals[0].2 == 40)
            #expect(totals[0].3 == 20.0)

            let bounds = try await repo.one(Post.select { ($0.viewCount.min(), $0.viewCount.max()) })
            #expect(bounds?.0 == 5)
            #expect(bounds?.1 == 30)

            // Aggregates over zero rows are NULL — hence the optionals.
            let empty = try await repo.one(
                Post.where { $0.title == "missing" }.select { ($0.viewCount.sum(), $0.viewCount.avg()) })
            #expect(empty?.0 == nil)
            #expect(empty?.1 == nil)
        }
    }

    @Test("select(into:) decodes a named Decodable type by alias")
    func selectInto() async throws {
        struct AuthorSummary: Decodable, Sendable, Equatable {
            let author: UUID
            let posts: Int
            let topTitle: String?
        }
        try await withRepo { repo in
            let author = UUID()
            for title in ["alpha", "omega"] {
                var post = Post.sample(title: title)
                post.authorID = author
                try await repo.insert(post)
            }
            let summaries = try await repo.all(
                Post.groupBy { $0.authorID }
                    .select(into: AuthorSummary.self) {
                        (author: $0.authorID, posts: $0.id.count(), topTitle: $0.title.max())
                    })
            #expect(summaries == [AuthorSummary(author: author, posts: 2, topTitle: "omega")])
        }
    }

    @Test("distinct and IN-list")
    func distinctAndInList() async throws {
        try await withRepo { repo in
            let shared = UUID()
            for title in ["a", "b"] {
                var post = Post.sample(title: title)
                post.authorID = shared
                try await repo.insert(post)
            }
            let authors: [UUID] = try await repo.all(Post.select { $0.authorID }.distinct())
            #expect(authors == [shared])

            let titles: [String] = try await repo.all(
                Post.where { $0.title.in(["a", "zzz"]) }.select { $0.title })
            #expect(titles == ["a"])
        }
    }

    @Test("IN subquery: posts by authors selected in a nested query (§8)")
    func inSubquery() async throws {
        try await withRepo { repo in
            let ada = try await repo.insert(Author(id: UUID(), name: "ada"))
            let ghost = try await repo.insert(Author(id: UUID(), name: "ghost"))
            var kept = Post.sample(title: "kept")
            kept.authorID = ada.id
            var dropped = Post.sample(title: "dropped")
            dropped.authorID = ghost.id
            try await repo.insert(kept)
            try await repo.insert(dropped)

            let adaIDs = Author.where { $0.name == "ada" }.select { $0.id }
            let posts = try await repo.all(Post.where { $0.authorID.in(adaIDs) })
            #expect(posts.map(\.title) == ["kept"])
        }
    }

    @Test("upsert doUpdate: second insert updates only the set columns")
    func upsertDoUpdate() async throws {
        try await withRepo { repo in
            let first = try await repo.insert(
                Changeset(KV.self).change(\.key, "color").change(\.value, "red"),
                onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
            let second = try await repo.insert(
                Changeset(KV.self).change(\.key, "color").change(\.value, "blue"),
                onConflict: .doUpdate(target: [\KV.key], set: [\KV.value]))
            #expect(first?.value == "red")
            #expect(second?.value == "blue")
            #expect(second?.id == first?.id)  // same row, updated
            let count = try await repo.count(KV.all)
            #expect(count == 1)
        }
    }

    @Test("upsert doNothing: the conflicting insert is skipped and returns nil")
    func upsertDoNothing() async throws {
        try await withRepo { repo in
            let first = try await repo.insert(
                Changeset(KV.self).change(\.key, "color").change(\.value, "red"),
                onConflict: .doNothing)
            let skipped = try await repo.insert(
                Changeset(KV.self).change(\.key, "color").change(\.value, "blue"),
                onConflict: .doNothing)
            #expect(first != nil)
            #expect(skipped == nil)
            let values: [String] = try await repo.all(KV.select { $0.value })
            #expect(values == ["red"])
        }
    }
}
}
