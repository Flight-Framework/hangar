// The README's common-table-expression examples, as code the build compiles.
//
// A README that shows an API is a claim about that API. These are the
// shapes the README's CTE section uses, so a signature change there breaks
// the build here rather than only misleading a reader.
import Foundation
import Hangar

// snippet.hide
@Entity("hangar_posts")
struct SnippetPost: Sendable {
    @ID var id: UUID
    var title: String
    @Column("view_count") var viewCount: Int
}

@Entity("hangar_nodes")
struct SnippetNode: Sendable {
    @ID var id: UUID
    var name: String
    @Column("parent_id") var parentID: UUID?
}
// snippet.show

func cteShapes(repo: Repo, rootID: UUID) async throws {
    // `with` names a subquery; `reading(from:)` makes it the source.
    let busy =
        SnippetPost.all
        .with("busy", as: SnippetPost.where { $0.viewCount > 50 })
        .reading(from: "busy")
        .order { $0.title.asc() }

    _ = try await repo.all(busy)

    // A recursive CTE: typed anchor, raw step. The step is the half that
    // refers to the CTE being defined.
    let subtree =
        SnippetNode.all
        .withRecursive(
            "subtree",
            anchor: SnippetNode.where { $0.id == rootID },
            recursive: """
                SELECT "hangar_nodes".* FROM "hangar_nodes" \
                JOIN "subtree" ON "hangar_nodes"."parent_id" = "subtree"."id"
                """)
        .reading(from: "subtree")

    _ = try await repo.all(subtree)

    // A CTE may feed a bulk delete; it cannot be its target.
    _ = try await repo.delete(
        SnippetPost.all
            .with("doomed", as: SnippetPost.where { $0.viewCount == 0 })
            .where { _ in
                SQLFragment(#""hangar_posts"."id" IN (SELECT "id" FROM "doomed")"#)
            })
}
