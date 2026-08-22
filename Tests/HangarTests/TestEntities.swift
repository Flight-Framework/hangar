import Foundation
import Hangar

// The entities the unit and integration suites share. Compiled through the
// real macro — these types are themselves the proof that the expansion
// compiles and satisfies `Table`.

enum PostStatus: String, PostgresEnum {
    case draft, published, archived
}

extension PostStatus: DynamicFilterConvertible {}

// The §9.1 allowlist: authorID (and everything else) deliberately absent.
extension Post: DynamicallyFilterable {
    static let filterable: [String: AnyColumn<Post>] = [
        "title": .init(\.title),
        "published": .init(\.published),
        "view_count": .init(\.viewCount),
        "nickname": .init(\.nickname),
        "status": .init(\.status),
    ]
}

struct PostMetadata: Codable, Equatable, Sendable {
    var tags: [String]
    var readingMinutes: Int
}

@Entity("hangar_posts")
struct Post: Sendable, Equatable {
    @ID let id: UUID
    var title: String
    var published: Bool
    var viewCount: Int
    @Column("created_at") var createdAt: Date
    var nickname: String?
    var status: PostStatus
    @JSONB var metadata: PostMetadata
    var authorID: UUID

    @HasMany(foreignKey: \Comment.postID)
    var comments: Loadable<[Comment]>

    @BelongsTo(foreignKey: \Post.authorID)
    var author: Loadable<Author>
}

@Entity("hangar_authors")
struct Author: Sendable, Equatable {
    @ID let id: UUID
    var name: String

    @HasOne(foreignKey: \Profile.authorID)
    var profile: Loadable<Profile?>

    @HasMany(foreignKey: \Post.authorID)
    var posts: Loadable<[Post]>
}

@Entity("hangar_comments")
struct Comment: Sendable, Equatable {
    @ID let id: UUID
    var postID: UUID
    var authorID: UUID
    var moderatorID: UUID?
    var body: String

    @BelongsTo(foreignKey: \Comment.authorID)
    var author: Loadable<Author>

    // Nullable FK: .loaded(nil) means "no moderator", not "not fetched".
    @BelongsTo(foreignKey: \Comment.moderatorID)
    var moderator: Loadable<Author?>
}

@Entity("hangar_profiles")
struct Profile: Sendable, Equatable {
    @ID let id: UUID
    var authorID: UUID
    var bio: String
}

extension Post {
    static func sample(
        title: String = "Hello, Hangar",
        published: Bool = true,
        viewCount: Int = 42,
        nickname: String? = nil,
        status: PostStatus = .published
    ) -> Post {
        Post(
            id: UUID(),
            title: title,
            published: published,
            viewCount: viewCount,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            nickname: nickname,
            status: status,
            metadata: PostMetadata(tags: ["swift", "postgres"], readingMinutes: 7),
            authorID: UUID())
    }
}

@Entity("hangar_events")
struct Event: Sendable, Equatable {
    @ID(generated: true) var id: Int = 0
    var name: String
}

// Upsert fixture (§6.2): "key" carries a UNIQUE constraint to conflict on.
@Entity("hangar_kv")
struct KV: Sendable, Equatable {
    @ID(generated: true) var id: Int = 0
    var key: String
    var value: String
}
