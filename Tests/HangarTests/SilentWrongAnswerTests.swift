import Testing

@testable import Hangar

/// Each test here pins a query that used to render *successfully* and return
/// the wrong answer. Silent wrong answers are the worst failure a query
/// builder can have — nothing throws, nothing logs, the number is just wrong —
/// so they get their own suite.
@Suite("Silent wrong answers")
struct SilentWrongAnswerTests {

 // MARK: - Joins used to discard grouping

 @Test("a join carries GROUP BY through")
 func joinCarriesGrouping() throws {
 let sql = try SQLRenderer.select(
 Post.all
 .groupBy { $0.authorID }
 .join(Comment.self, on: { post, comment in comment.postID == post.id })
 ).sql
 #expect(sql.contains("GROUP BY"), "grouping must survive composition into a join")
 }

 @Test("a join carries HAVING through")
 func joinCarriesHaving() throws {
 let sql = try SQLRenderer.select(
 Post.all
 .groupBy { $0.authorID }
 .having { $0.viewCount.sum() > 5 }
 .join(Comment.self, on: { post, comment in comment.postID == post.id })
 ).sql
 #expect(sql.contains("GROUP BY"))
 #expect(sql.contains("HAVING"), "a HAVING filter must survive composition into a join")
 }

 @Test("composition order does not change the result")
 func compositionOrderIsIrrelevant() throws {
 // Build the join first, then group — the order the original tests used.
 let groupedAfter = try SQLRenderer.select(
 Post.all
 .join(Comment.self, on: { post, comment in comment.postID == post.id })
 .groupBy { post, _ in post.authorID }
 ).sql
 // Group first, then join — the order that used to silently drop it.
 let groupedBefore = try SQLRenderer.select(
 Post.all
 .groupBy { $0.authorID }
 .join(Comment.self, on: { post, comment in comment.postID == post.id })
 ).sql
 #expect(groupedAfter.contains("GROUP BY"))
 #expect(groupedBefore.contains("GROUP BY"))
 }

 // MARK: - count / exists used to ignore what a row is

 @Test("count over a grouped query counts groups, not rows")
 func countRespectsGrouping() {
 let sql = SQLRenderer.count(Post.all.groupBy { $0.authorID }).sql
 #expect(sql.contains("GROUP BY"), "counting without the grouping counts the wrong thing")
 #expect(sql.lowercased().contains("from ("), "a grouped count must wrap in a subquery")
 }

 @Test("count over a distinct query counts distinct rows")
 func countRespectsDistinct() {
 let sql = SQLRenderer.count(Post.all.select { $0.authorID }.distinct()).sql
 #expect(sql.contains("DISTINCT"))
 #expect(sql.lowercased().contains("from ("))
 }

 @Test("count respects HAVING")
 func countRespectsHaving() {
 let sql = SQLRenderer.count(
 Post.all.groupBy { $0.authorID }.having { $0.viewCount.sum() > 5 }
 ).sql
 #expect(sql.contains("HAVING"))
 }

 @Test("exists respects HAVING, which can empty an otherwise-matching set")
 func existsRespectsHaving() {
 let sql = SQLRenderer.exists(
 Post.all.groupBy { $0.authorID }.having { $0.viewCount.sum() > 1_000_000 }
 ).sql
 #expect(sql.contains("HAVING"), "ignoring HAVING would report true for an empty result")
 }

 @Test("a plain count stays a plain count — no needless subquery")
 func plainCountIsUnchanged() {
 let sql = SQLRenderer.count(Post.all.where { $0.viewCount > 3 }).sql
 #expect(sql.hasPrefix("SELECT count(*) FROM"))
 #expect(!sql.lowercased().contains("from ("), "no subquery when nothing requires one")
 #expect(sql.contains("WHERE"))
 }

 @Test("ordering and pagination are still ignored by count")
 func countIgnoresOrderingAndPaging() {
 let sql = SQLRenderer.count(
 Post.all.groupBy { $0.authorID }.order { $0.id.asc() }.limit(10).offset(5)
 ).sql
 // They do not change how many rows match, and ORDER BY is invalid in
 // this position anyway.
 #expect(!sql.contains("ORDER BY"))
 #expect(!sql.contains("LIMIT"))
 #expect(!sql.contains("OFFSET"))
 }
}
