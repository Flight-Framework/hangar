import Foundation
import Testing

@testable import Hangar

// Design: "Spike before Phase 1: the &&/|| overload question."
//
// The question: Swift's standard `&&` takes an `@autoclosure  -> Bool`
// right operand. Does overloading `&&`/`||` over PredicateConvertible
// resolve cleanly — for predicates AND for ordinary Bool expressions in the
// same file — or does overload resolution turn ambiguous?
//
// Verdict, pinned by this suite compiling and passing: it resolves. Since
// `Predicate` and `Column<Bool>` are not `Bool`, the standard-library
// overloads never compete on predicate operands, and Bool-only expressions
// never see the Hangar overloads. The  fallback (.and/.or chaining)
// is not needed.

@Suite("Boolean combinators — &&/|| overload resolution")
struct PredicateSpikeTests {

    @Test("mixed comparison + bool-column expressions resolve and render")
    func mixedExpressions() {
        let statement = SQLRenderer.select(
            Post.where { $0.published == true && $0.viewCount > 100 })
        #expect(statement.sql.contains(#"(("published" = $1) AND ("view_count" > $2))"#))
    }

    @Test("bare bool columns combine with comparisons at both positions")
    func bareBoolColumns() {
        let left = SQLRenderer.select(Post.where { $0.published && $0.viewCount > 3 })
        #expect(left.sql.contains(#"("published" AND ("view_count" > $1))"#))

        let right = SQLRenderer.select(Post.where { $0.viewCount > 3 && $0.published })
        #expect(right.sql.contains(#"(("view_count" > $1) AND "published")"#))
    }

    @Test("nesting and negation compose with explicit precedence")
    func nestedComposition() {
        let statement = SQLRenderer.select(
            Post.where { $0.published && ($0.viewCount > 3 || $0.title == "pinned") && !($0.nickname == nil) })
        #expect(statement.sql.contains(
            #"(("published" AND (("view_count" > $1) OR ("title" = $2))) AND NOT (("nickname" IS NULL)))"#))
    }

    @Test("plain Bool && / || in the same file still short-circuits untouched")
    func plainBoolUnaffected() {
        var evaluated = false
        func sideEffect() -> Bool {
            evaluated = true
            return true
        }
        let result = false && sideEffect()
        #expect(result == false)
        #expect(evaluated == false, "standard-library short-circuiting must survive the overloads")
        #expect(true || sideEffect())
        #expect(evaluated == false)
    }

    @Test("queries are values: composition never mutates the original")
    func valueSemantics() {
        let base = Post.where { $0.published }
        _ = base.where { $0.viewCount > 10 }.limit(1)
        let statement = SQLRenderer.select(base)
        #expect(statement.sql.hasSuffix(#"WHERE "published""#))
    }
}
