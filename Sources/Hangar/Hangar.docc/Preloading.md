# Preloading associations

Loading related rows without N+1, and why an unloaded association throws.

## Overview

An association is declared on the model and loaded on demand:

```swift
@Entity("posts")
struct Post {
    @ID var id: UUID
    @Column var authorID: UUID
    @BelongsTo(\.authorID) var author: Loadable<Author>
    @HasMany(\Comment.postID) var comments: Loadable<[Comment]>
}
```

```swift
let posts = try await repo.all(Post.all.preload(\.author).preload(\.comments))
```

## One query per association, not one per row

Preloading collects the keys from the parent rows and issues a single query
per association using `= ANY($1)` — one bound array, however many keys. Three
associations on a hundred posts is four queries, not three hundred and one.

Preloads run sequentially rather than concurrently, which is the safe default
but does mean three associations are three round trips.

> Note: Key sets are not chunked. A hundred thousand parents means a
> hundred-thousand-element bind, and that has not been measured past a
> thousand. If you are preloading over very large result sets, page the
> parents.

## Accessing what you loaded

``Loadable`` is a small enum: loaded, or not.

```swift
for post in posts {
    let author = try post.author.require()      // throws if not preloaded
}
```

``Loadable/isLoaded`` asks without throwing, when the answer is genuinely
optional.

## Why it throws

An unloaded association could have returned an empty array. It does not,
deliberately.

An empty array is indistinguishable from "this post genuinely has no
comments", so the mistake would surface as a page that renders correctly and
silently omits data — the hardest kind of bug to notice. Throwing turns a
forgotten `.preload` into an immediate, obvious failure with the association
named.

## Nested preloads

An association's own associations load too, and the inner query can be tuned:

```swift
Post.all.preload(\.comments) { comments in
    comments.where { $0.approved == true }.order { $0.createdAt.asc() }
}
```

## Preloading through a join

Preloads survive composition into a join, and apply to the base entity:

```swift
Post.join(Comment.self, on: { p, c in c.postID == p.id })
    .preload(\.author)
```
