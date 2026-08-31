// The README's soft-delete examples, as code the build compiles.
//
// A README that shows an API is a claim about that API. The soft-delete
// section had no snippet, and it showed `StoredFile.onlyDeleted()` — a
// spelling that did not exist, since the scope operators lived on `Query`
// with no static sugar beside `where`/`order`/`limit`. Nobody noticed
// because nothing compiled it. Now something does.
import Foundation
import Hangar

// snippet.hide
@Entity("hangar_authors")
struct SnippetOwner: Sendable {
    @ID var id: UUID
    var name: String
}

@Entity("hangar_files")
struct SnippetFile: Sendable {
    @ID var id: UUID
    var name: String
    @Column("owner_id") var ownerID: UUID
    @Deleted @Column("deleted_at") var deletedAt: Date?
}
// snippet.show

func softDeleteShapes(repo: Repo, cutoff: Date) async throws {
    // Reads exclude deleted rows by default; the escape hatches are named.
    _ = try await repo.all(SnippetFile.all)
    _ = try await repo.all(SnippetFile.withDeleted())
    _ = try await repo.all(SnippetFile.onlyDeleted())

    // The trash-view purge: only-deleted rows past their retention window.
    // `<` on a nullable column is what makes this an ordinary query.
    try await repo.delete(SnippetFile.onlyDeleted().where { $0.deletedAt < cutoff })

    // The scope survives a join, in every form. The base entity's rows are
    // scoped in WHERE; a soft-deletable *joined* table excludes its own
    // deleted rows in the ON clause, so a LEFT JOIN stays outer.
    _ = try await repo.all(
        SnippetFile.onlyDeleted()
            .join(SnippetOwner.self, on: { file, owner in owner.id == file.ownerID }))

    _ = try await repo.all(
        SnippetOwner.leftJoin(SnippetFile.self, on: { owner, file in file.ownerID == owner.id })
            .distinct())

    // Composed joins take the same scope operators.
    _ = try await repo.all(
        SnippetFile.query { q, file in
            _ = q.join(SnippetOwner.self) { $0.id == file.ownerID }
            q.withDeleted()
            return q.query()
        })
}
