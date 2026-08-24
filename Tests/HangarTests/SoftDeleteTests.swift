import Foundation
import Testing

@testable import Hangar

/// Soft deletion.
///
/// The property under test throughout is that a deleted row stops appearing
/// *by default*, on every read path. A soft delete that one code path
/// forgets is worse than none: the row looks gone in a list and reappears in
/// a count, and nothing errors.
@Suite("Soft delete", .serialized)
struct SoftDeleteTests {

    private func seed(_ repo: Repo) async throws -> (live: StoredFile, doomed: StoredFile) {
        let owner = try await repo.insert(Author(id: UUID(), name: "Owner"))
        let live = try await repo.insert(
            StoredFile(
                id: UUID(), name: "keep.txt", sizeBytes: 10, ownerID: owner.id, deletedAt: nil))
        let doomed = try await repo.insert(
            StoredFile(
                id: UUID(), name: "bin.txt", sizeBytes: 20, ownerID: owner.id, deletedAt: nil))
        return (live, doomed)
    }

    @Test("an entity with a @Deleted column says so")
    func detectsTheColumn() {
        #expect(StoredFile.isSoftDeletable)
        #expect(StoredFile.schema.deletedAt?.name == "deleted_at")
        // A model without the marker is unaffected.
        #expect(!Post.isSoftDeletable)
        #expect(Post.schema.deletedAt == nil)
    }

    @Test("delete stamps rather than removes")
    func deleteIsSoft() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // Gone from the default view...
            #expect(try await repo.all(StoredFile.all).count == 1)
            // ...but still in the table.
            let raw = try await repo.all(StoredFile.all.withDeleted())
            #expect(raw.count == 2)
            #expect(raw.first { $0.id == doomed.id }?.deletedAt != nil)
        }
    }

    @Test("every read path excludes deleted rows, not just the obvious one")
    func exclusionIsUniform() async throws {
        try await withRepo { repo in
            let (live, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // The paths that would each need to remember on their own.
            #expect(try await repo.all(StoredFile.all).count == 1)
            #expect(try await repo.count(StoredFile.all) == 1)
            #expect(try await repo.one(StoredFile.where { $0.id == doomed.id }) == nil)
            #expect(try await repo.exists(StoredFile.where { $0.id == doomed.id }) == false)
            #expect(try await repo.exists(StoredFile.where { $0.id == live.id }) == true)
        }
    }

    @Test("a predicate composes with the exclusion rather than replacing it")
    func predicateComposes() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // Matches the deleted row on name, and must still find nothing.
            #expect(try await repo.all(StoredFile.where { $0.name == "bin.txt" }).isEmpty)
            #expect(
                try await repo.all(StoredFile.where { $0.name == "bin.txt" }.withDeleted()).count
                    == 1)
        }
    }

    @Test("withDeleted and onlyDeleted select the other views")
    func scopes() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            #expect(try await repo.count(StoredFile.all) == 1)
            #expect(try await repo.count(StoredFile.all.withDeleted()) == 2)
            #expect(try await repo.count(StoredFile.all.onlyDeleted()) == 1)
            #expect(try await repo.all(StoredFile.all.onlyDeleted()).first?.id == doomed.id)
        }
    }

    @Test("restore brings a row back")
    func restore() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)
            #expect(try await repo.count(StoredFile.all) == 1)

            try await repo.restore(doomed)
            #expect(try await repo.count(StoredFile.all) == 2)
            let back = try await repo.one(StoredFile.where { $0.id == doomed.id })
            #expect(back?.deletedAt == nil)
        }
    }

    @Test("deleting twice is reported, not silently re-stamped")
    func deletingTwice() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)
            await #expect(throws: HangarError.self) { try await repo.delete(doomed) }
        }
    }

    @Test("restoring something that was never deleted is reported")
    func restoringALiveRow() async throws {
        try await withRepo { repo in
            let (live, _) = try await seed(repo)
            await #expect(throws: HangarError.self) { try await repo.restore(live) }
        }
    }

    @Test("forceDelete removes the row for real")
    func forceDelete() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.forceDelete(doomed)

            // Not merely hidden — absent even from the unfiltered view.
            #expect(try await repo.count(StoredFile.all.withDeleted()) == 1)
        }
    }

    @Test("soft-deleting a model without the column is refused")
    func notSoftDeletable() async throws {
        try await withRepo { repo in
            let author = try await repo.insert(Author(id: UUID(), name: "Ada"))
            await #expect(throws: HangarError.self) { try await repo.softDelete(author) }
            // delete still works — it hard-deletes, which is what the model means.
            try await repo.delete(author)
            #expect(try await repo.count(Author.all) == 0)
        }
    }

    @Test("preloading does not resurrect deleted children")
    func preloadExcludesDeleted() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // The association is loaded by a separate query from the parent's,
            // so this is the path most likely to forget the exclusion — and
            // the one where forgetting is least visible, since the parent list
            // looks right and only the nested array is wrong.
            let owners = try await repo.all(Author.all.preload(\.files))
            let files = try owners[0].files.get()
            #expect(files.count == 1)
            #expect(files.first?.name == "keep.txt")
        }
    }

    @Test("a preload can opt in to deleted children")
    func preloadCanIncludeDeleted() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            // The nested tune is an ordinary query builder, so the same
            // opt-in works there.
            let owners = try await repo.all(
                Author.all.preload(\.files) { $0.withDeleted() })
            #expect(try owners[0].files.get().count == 2)
        }
    }

    @Test("a set-based update skips deleted rows by default")
    func setBasedUpdateSkipsDeleted() async throws {
        try await withRepo { repo in
            let (_, doomed) = try await seed(repo)
            try await repo.delete(doomed)

            let touched = try await repo.update(StoredFile.all) { $0.sizeBytes.set(to: 999) }
            #expect(touched == 1, "the deleted row must not be updated")

            let all = try await repo.all(StoredFile.all.withDeleted())
            #expect(all.first { $0.id == doomed.id }?.sizeBytes == 20)
        }
    }
}
