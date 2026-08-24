// The README's `Multi` example, as code the build compiles.
//
// A README that shows an API is a claim about that API. These are the shapes
// the README's Multi section uses, so a signature change there breaks the
// build here rather than only misleading a reader.
import Changesets
import Foundation
import Hangar

// snippet.hide
@Entity("users")
struct SnippetUser: Sendable {
    @ID var id: UUID
    var email: String
}
// snippet.show

enum K {
    static let user = MultiKey<SnippetUser>("user")
}

func multiShapes(changeset: Changeset<SnippetUser>) throws {
    // Steps are values: build one, compose it, and only then run it. A
    // dependent step reads earlier results through their typed keys.
    let multi = Multi()
        .insert(K.user, changeset)
        .run(MultiKey<Void>("email")) { results in
            _ = try results[K.user]
        }

    _ = multi.merging(Multi())
}

func readResult(_ result: MultiResult) {
    switch result {
    case .success(let values):
        _ = try? values[K.user]
    case .failure(let failure):
        // The failed step names itself, and carries what completed before it.
        _ = (failure.key, failure.error, failure.completed)
    }
}
