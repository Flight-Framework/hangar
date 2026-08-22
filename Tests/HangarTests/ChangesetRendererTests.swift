import Foundation
import Testing

@testable import Hangar

// Changeset → SQL (design §11.2): minimal writes. Only changed fields
// appear in the column list / SET clause, in schema order regardless of
// change order.

@Suite("Changeset statements — minimal, schema-ordered")
struct ChangesetRendererTests {

    private let allColumns =
        #""id", "title", "published", "view_count", "created_at", "nickname", "status", "metadata", "author_id""#

    @Test("insert lists only changed fields, in schema order")
    func minimalInsert() throws {
        let changeset = Changeset(Post.self)
            .change(\.viewCount, 5)
            .change(\.title, "hello")
        let statement = try SQLRenderer.insert(try changeset.validatedChanges(), into: Post.self)
        #expect(statement.sql == """
            INSERT INTO "hangar_posts" ("title", "view_count") \
            VALUES ($1, $2) RETURNING \(allColumns)
            """)
        #expect(statement.binds.count == 2)
    }

    @Test("an empty insert changeset falls back to DEFAULT VALUES")
    func emptyInsert() throws {
        let statement = try SQLRenderer.insert(
            try Changeset(Post.self).validatedChanges(), into: Post.self)
        #expect(statement.sql == #"INSERT INTO "hangar_posts" DEFAULT VALUES RETURNING \#(allColumns)"#)
    }

    @Test("update SETs only dirty fields and filters by the original's key")
    func minimalUpdate() throws {
        var changed = Post.sample(title: "before")
        changed.title = "before"  // unchanged relative to itself
        let changeset = Changeset(original: changed)
            .change(\.title, "after")
            .change(\.published, changed.published)  // reverts to original — not dirty
        let statement = try SQLRenderer.update(try changeset.validatedChanges(), into: Post.self)
        #expect(statement.sql == """
            UPDATE "hangar_posts" SET "title" = $1 \
            WHERE "id" = $2 \
            RETURNING \(allColumns)
            """)
        #expect(statement.binds.count == 2)
    }

    @Test("an insert changeset handed to update is refused: no identity")
    func updateWithoutIdentity() throws {
        let validated = try Changeset(Post.self).change(\.title, "x").validatedChanges()
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.update(validated, into: Post.self)
        }
    }

    @Test("a mistyped erased value is caught before the wire")
    func valueMismatch() {
        // Hand-built ValidatedChanges (the public init exists for driver
        // tests) boxing an Int where the column is text.
        let validated = ValidatedChanges(changedFields: ["title": 42], identity: nil)
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.insert(validated, into: Post.self)
        }
    }

    @Test("a field name outside the schema is refused")
    func strayField() {
        let validated = ValidatedChanges(changedFields: ["bogus": "x"], identity: nil)
        #expect(throws: HangarError.self) {
            _ = try SQLRenderer.insert(validated, into: Post.self)
        }
    }

    @Test("@Entity's TableModel metadata matches its schema by construction")
    func tableModelMetadata() {
        #expect(Post.tableName == Post.schema.name)
        #expect(Post.columns.map(\.name) == Post.schema.columns.map(\.name))
        #expect(Post.primaryKey.map(\.name) == Post.schema.primaryKey.map(\.name))
        #expect(Event.columns.map(\.name) == ["id", "name"])
    }
}
