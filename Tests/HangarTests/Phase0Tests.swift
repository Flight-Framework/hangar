import Foundation
import Testing

@testable import Hangar

// MARK: - Bulk delete rendering

@Suite("Bulk delete — SQL")
struct BulkDeleteRendererTests {

    @Test("delete(query) renders DELETE ... WHERE ... RETURNING pk")
    func rendersPredicateDelete() throws {
        let statement = try SQLRenderer.delete(Post.where { $0.published == false })
        #expect(
            statement.sql
                == #"DELETE FROM "hangar_posts" WHERE ("published" = $1) RETURNING "id""#)
        #expect(statement.binds.count == 1)
    }

    @Test("a query with no predicate deletes the whole table — explicitly")
    func wholeTable() throws {
        let statement = try SQLRenderer.delete(Post.all)
        #expect(statement.sql == #"DELETE FROM "hangar_posts" RETURNING "id""#)
    }

    @Test("clauses DELETE cannot honor are refused, naming the clause")
    func refusesUnsupportedClauses() throws {
        // A delete that ignored the LIMIT you wrote would delete rows you
        // did not ask it to — the silent-wrong-answer shape this library
        // refuses on principle.
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.limit(5))
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.offset(5))
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.order { $0.id.asc() })
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.groupBy { $0.authorID })
        }
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.delete(Post.all.distinct())
        }
        do {
            _ = try SQLRenderer.delete(Post.all.limit(5))
            Issue.record("expected a throw")
        } catch let error as HangarError {
            #expect(error.description.contains("LIMIT"))
        }
    }
}

// MARK: - SQLFragment column qualification

@Suite("SQLFragment — column qualification")
struct FragmentQualificationTests {

    @Test("in a single-table scope a fragment column renders bare")
    func singleTableBare() {
        let statement = SQLRenderer.select(
            Post.where { p in SQLFragment("char_length(\(p.title)) > \(3)") })
        #expect(statement.sql.contains(#"char_length("title")"#))
        #expect(statement.binds.count == 1)
    }

    @Test("inside a join a fragment column renders table-qualified")
    func joinQualified() throws {
        // Two tables share one namespace; a bare "title" would be ambiguous
        // or, worse, silently resolve to the wrong table.
        let statement = try SQLRenderer.select(
            Post.join(Comment.self, on: { p, c in c.postID == p.id })
                .where { p, _ in SQLFragment("char_length(\(p.title)) > \(3)") })
        #expect(statement.sql.contains(#"char_length("hangar_posts"."title")"#))
    }
}

// MARK: - Array columns

@Suite("Array columns — SQL")
struct ArrayColumnRendererTests {

    @Test("an entity with array columns renders and binds like any other")
    func insertShape() throws {
        let statement = try SQLRenderer.insert(
            Tagged(name: "a", labels: ["x", "y"], scores: [1, 2]))
        #expect(statement.sql.contains(#""labels""#))
        #expect(statement.sql.contains(#""scores""#))
        // name + labels + scores (id is database-generated)
        #expect(statement.binds.count == 3)
    }
}

// MARK: - Integration

extension PostgresIntegrationSuite {
    @Suite("Phase 0 — bulk delete and array columns (real Postgres)")
    struct Phase0IntegrationTests {

        @Test("bulk delete removes exactly the matching rows and reports the count")
        func bulkDelete() async throws {
            try await withRepo { repo in
                for i in 1...5 {
                    try await repo.insert(Post.sample(title: "keep-\(i)"))
                }
                var doomed = Post.sample(title: "doomed")
                doomed.published = false
                try await repo.insert(doomed)

                let removed = try await repo.delete(Post.where { $0.published == false })
                #expect(removed == 1)
                #expect(try await repo.count(Post.all) == 5)

                // Nothing matched: zero is an answer, not an error.
                let none = try await repo.delete(Post.where { $0.published == false })
                #expect(none == 0)
            }
        }

        @Test("array columns round-trip, including the empty array")
        func arrayRoundTrip() async throws {
            try await withRepo { repo in
                let stored = try await repo.insert(
                    Tagged(name: "full", labels: ["swift", "postgres"], scores: [7, 11]))
                #expect(stored.labels == ["swift", "postgres"])
                #expect(stored.scores == [7, 11])

                let empty = try await repo.insert(Tagged(name: "empty", labels: [], scores: []))
                #expect(empty.labels.isEmpty)
                #expect(empty.scores.isEmpty)

                let fetched = try await repo.all(Tagged.all.order { $0.id.asc() })
                #expect(fetched.map(\.labels) == [["swift", "postgres"], []])

                // Arrays update like any other column.
                var updated = stored
                updated.labels = ["renamed"]
                let written = try await repo.update(updated)
                #expect(written.labels == ["renamed"])
            }
        }
    }
}

// MARK: - Multi throwing subscript

@Suite("MultiValues — throwing subscript")
struct MultiValuesThrowingTests {

    @Test("a missing key throws, and names the key")
    func missingKeyThrows() throws {
        let values = MultiValues()
        do {
            _ = try values[MultiKey<Int>("absent")]
            Issue.record("expected a throw")
        } catch let error as HangarError {
            #expect(error.description.contains("absent"))
        }
    }

    @Test("a same-name key with a different type throws, naming both types")
    func typeMismatchThrows() throws {
        var values = MultiValues()
        values.storage["shared"] = 42
        do {
            _ = try values[MultiKey<String>("shared")]
            Issue.record("expected a throw")
        } catch let error as HangarError {
            #expect(error.description.contains("Int"))
            #expect(error.description.contains("String"))
        }
    }
}

extension PostgresIntegrationSuite {
    @Suite("Multi — step misuse fails the transaction, not the process")
    struct MultiMisuseIntegrationTests {

        @Test("a step reading an unknown key rolls back and reports through .failure")
        func unknownKeyBecomesStepFailure() async throws {
            try await withRepo { repo in
                let multi = Multi()
                    .insert(MultiKey<Post>("post"), postChangeset(title: "will roll back"))
                    .run { values in
                        _ = try values[MultiKey<Int>("no-such-step")]
                    }
                switch try await repo.run(multi) {
                case .success:
                    Issue.record("expected the misreading step to fail the Multi")
                case .failure(let failure):
                    #expect(failure.error is HangarError)
                    // The insert before it was rolled back with everything else.
                    #expect(try await repo.count(Post.all) == 0)
                }
            }
        }
    }
}

// MARK: - Bulk update

@Suite("Bulk update — SQL")
struct BulkUpdateRendererTests {

    @Test("update(query, set:) renders UPDATE ... SET ... WHERE ... RETURNING pk")
    func rendersPredicateUpdate() throws {
        let statement = try SQLRenderer.update(
            Post.where { $0.published == false },
            set: [
                Post.queryColumns.published.set(to: true)._assignment,
                Post.queryColumns.viewCount.set(to: 0)._assignment,
            ])
        #expect(
            statement.sql
                == #"UPDATE "hangar_posts" SET "published" = $1, "view_count" = $2 WHERE ("published" = $3) RETURNING "id""#)
        #expect(statement.binds.count == 3)
    }

    @Test("setting an optional column to nil writes SQL NULL through a bind")
    func nilAssignment() throws {
        let statement = try SQLRenderer.update(
            Post.all,
            set: [Post.queryColumns.nickname.set(to: nil)._assignment])
        #expect(statement.sql == #"UPDATE "hangar_posts" SET "nickname" = $1 RETURNING "id""#)
    }

    @Test("an empty SET throws rather than rendering UPDATE ... SET nothing")
    func emptySetRefused() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.update(Post.all, set: [])
        }
    }

    @Test("clauses UPDATE cannot honor are refused, same rule as bulk delete")
    func refusesUnsupportedClauses() {
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.update(
                Post.all.limit(3),
                set: [Post.queryColumns.published.set(to: true)._assignment])
        }
    }
}

extension PostgresIntegrationSuite {
    @Suite("Bulk update (real Postgres)")
    struct BulkUpdateIntegrationTests {

        @Test("one statement writes the matching rows and reports the count")
        func bulkUpdate() async throws {
            try await withRepo { repo in
                for i in 1...3 {
                    var draft = Post.sample(title: "draft-\(i)")
                    draft.published = false
                    try await repo.insert(draft)
                }
                try await repo.insert(Post.sample(title: "already-live"))

                let published = try await repo.update(Post.where { $0.published == false }) {
                    ($0.published.set(to: true), $0.nickname.set(to: "batch"))
                }
                #expect(published == 3)
                #expect(try await repo.count(Post.where { $0.published == false }) == 0)

                // The already-published row was outside the predicate: untouched.
                let untouched = try await repo.one(Post.where { $0.title == "already-live" })
                #expect(untouched?.nickname != "batch")

                // Zero matches is an answer, not an error.
                let none = try await repo.update(Post.where { $0.title == "no-such" }) {
                    ($0.published.set(to: false))
                }
                #expect(none == 0)
            }
        }

        @Test("arity 1: a single assignment needs no tuple ceremony")
        func singleAssignment() async throws {
            try await withRepo { repo in
                try await repo.insert(Post.sample(title: "solo"))
                let count = try await repo.update(Post.all) {
                    $0.nickname.set(to: nil)
                }
                #expect(count == 1)
                let row = try await repo.one(Post.all)
                #expect(row?.nickname == nil)
            }
        }
    }
}
