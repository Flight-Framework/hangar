/// An association's value: either preloaded or explicitly absent-from-this
///-fetch. The loaded/unloaded distinction is runtime, not
/// compile-time — deliberately: encoding the preload set in the model's
/// type poisons every signature that touches a model.
///
/// What the type buys instead:
/// - Accessing an unloaded association **never silently issues a query** —
///   no lazy loading, no invisible N+1.
/// - The failure is deterministic, not data-dependent: a code path that
///   forgot a preload fails on its *first* execution, so any test covering
///   it catches it.
/// - "No comments" (`.loaded([])`) and "comments not fetched"
///   (`.notLoaded`) are different values, not a conflated nil.
///
/// Throws rather than traps: forgetting a preload should fail one request,
/// not the node.
public enum Loadable<T: Sendable>: Sendable {
    /// Not fetched. Carries the association's name so the error can say
    /// *which* preload is missing (the case is macro-constructed; user code
    /// mostly writes `.loaded`).
    case notLoaded(association: String)
    case loaded(T)

    /// The loaded value, or `HangarError.notPreloaded` naming the
    /// association and telling you to preload it.
    public func get() throws -> T {
        switch self {
        case .loaded(let value):
            return value
        case .notLoaded(let association):
            throw HangarError.notPreloaded(association: association)
        }
    }

    /// Nil if not loaded — for call sites where absence is acceptable.
    /// Note the deliberate conflation this reintroduces for optional-typed
    /// associations; prefer `get` where the distinction matters.
    public var optional: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// Whether the association was preloaded — the non-throwing question,
    /// for when absence is genuinely acceptable.
    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

extension Loadable: Equatable where T: Equatable {}

/// JSON encoding, so a preloaded model can be serialized without a
/// hand-written mirror type: a loaded association encodes as its value, an
/// unloaded one as `null`.
///
/// **Encoding only, deliberately.** There is no matching `Decodable`: on the
/// wire `null` cannot distinguish "not fetched" from "fetched, and there is
/// genuinely nothing there" — the very distinction this type exists to keep.
/// A decoder would have to guess, and guessing wrong reintroduces the
/// conflated nil by the back door. Models come *out* of an application as
/// JSON; what comes *in* is a request type of its own.
extension Loadable: Encodable where T: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .loaded(let value):
            try container.encode(value)
        case .notLoaded:
            try container.encodeNil()
        }
    }
}
