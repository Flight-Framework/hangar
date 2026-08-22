/// An association's value: either preloaded or explicitly absent-from-this
///-fetch (design §7.3). The loaded/unloaded distinction is runtime, not
/// compile-time — deliberately: encoding the preload set in the model's
/// type poisons every signature that touches a model.
///
/// What the type buys instead:
/// - Accessing an unloaded association **never silently issues a query** —
///   no lazy loading, no invisible N+1 (§11.1).
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
    /// associations; prefer `get()` where the distinction matters.
    public var optional: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

extension Loadable: Equatable where T: Equatable {}
