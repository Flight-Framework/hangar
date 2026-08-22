import Foundation
import Testing

import Hangar

// `Multi` (design §10): typed keys, dependent steps, one transaction.

private enum K {
    static let post = MultiKey<Post>("post")
    static let event = MultiKey<Event>("event")
    static let summary = MultiKey<String>("summary")
    static let count = MultiKey<Int>("count")
    static let ghost = MultiKey<Post>("ghost")
}

extension PostgresIntegrationSuite {
@Suite(
    "Multi (real Postgres)",
    .enabled(if: TestDatabase.isConfigured, "set HANGAR_TEST_DATABASE_URL to run"))
struct MultiIntegrationTests {

    @Test("dependent steps see earlier results; success returns typed values")
    func dependentSteps() async throws {
        try await withRepo { repo in
            let multi = Multi()
                .insert(K.post, postChangeset(title: "multi post"))
                .insert(K.event) { values in
                    Changeset(Event.self).change(\.name, "event for \(values[K.post].title)")
                }
                .run(K.summary) { values in
                    "\(values[K.post].title) / \(values[K.event].name)"
                }

            switch try await repo.run(multi) {
            case .success(let values):
                #expect(values[K.post].title == "multi post")
                #expect(values[K.event].name == "event for multi post")
                #expect(values[K.summary] == "multi post / event for multi post")
            case .failure(let failure):
                Issue.record("unexpected failure at step '\(failure.key)': \(failure.error)")
            }
            let posts = try await repo.count(Post.all)
            let events = try await repo.count(Event.all)
            #expect(posts == 1)
            #expect(events == 1)
        }
    }

    @Test("a failing step rolls back every completed step")
    func failureRollsBack() async throws {
        try await withRepo { repo in
            let never = Post.sample(title: "never inserted")
            let multi = Multi()
                .insert(K.post, postChangeset(title: "doomed"))
                .update(K.ghost) { _ in
                    // The row does not exist → HangarError.staleModel.
                    Changeset(original: never).change(\.title, "x")
                }

            switch try await repo.run(multi) {
            case .success:
                Issue.record("the ghost update should have failed")
            case .failure(let failure):
                #expect(failure.key == "ghost")
                #expect(failure.error is HangarError)
                // The doomed insert had completed before the failure —
                // and was rolled back with it.
                #expect(failure.completed[K.post].title == "doomed")
            }
            let count = try await repo.count(Post.all)
            #expect(count == 0)
        }
    }

    @Test("run steps get the ambient transaction repo and read its writes")
    func runStepAmbient() async throws {
        try await withRepo { repo in
            let multi = Multi()
                .insert(K.post, postChangeset(title: "ambient"))
                .run(K.count) { _ in
                    // Repo.current is the transaction repo (§5.1), so this
                    // read sees the uncommitted insert above.
                    try await Repo.require().count(Post.all)
                }
            switch try await repo.run(multi) {
            case .success(let values):
                #expect(values[K.count] == 1)
            case .failure(let failure):
                Issue.record("unexpected failure at '\(failure.key)': \(failure.error)")
            }
        }
    }

    @Test("keyless run steps and deletes participate")
    func deleteAndSideEffect() async throws {
        try await withRepo { repo in
            let existing = try await repo.insert(Post.sample(title: "to delete"))
            let multi = Multi()
                .delete(K.ghost) { _ in existing }
                .run { values in
                    #expect(values[K.ghost].title == "to delete")
                }
            switch try await repo.run(multi) {
            case .success:
                let count = try await repo.count(Post.all)
                #expect(count == 0)
            case .failure(let failure):
                Issue.record("unexpected failure at '\(failure.key)': \(failure.error)")
            }
        }
    }

    @Test("duplicate step names are rejected before anything runs — merged Multis included")
    func duplicateKeys() async throws {
        try await withRepo { repo in
            // Built via merging (§10.1: Multis compose as values); the two
            // halves collide on K.post and the run must refuse up front.
            let first = Multi().insert(K.post, postChangeset(title: "a"))
            let second = Multi().insert(K.post, postChangeset(title: "b"))
            await #expect(throws: HangarError.self) {
                _ = try await repo.run(first.merging(second))
            }
            let count = try await repo.count(Post.all)
            #expect(count == 0)
        }
    }

    @Test("merged Multis run as one transaction in order")
    func merging() async throws {
        try await withRepo { repo in
            let writes = Multi().insert(K.post, postChangeset(title: "merged"))
            let checks = Multi().run(K.count) { _ in
                try await Repo.require().count(Post.all)
            }
            switch try await repo.run(writes.merging(checks)) {
            case .success(let values):
                #expect(values[K.count] == 1)
            case .failure(let failure):
                Issue.record("unexpected failure at '\(failure.key)': \(failure.error)")
            }
        }
    }
}
}
