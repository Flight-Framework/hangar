import Changesets

// `Multi` — transaction orchestration with typed keys.
// Steps are values: a Multi can be built conditionally, returned from a
// function, and passed around before it runs. Later steps see earlier
// results through the closure parameter; everything runs in one
// transaction, and any failure rolls back all of it.

/// A phantom-typed key naming one step's result — the same technique
/// `Container.resolve` uses: internally results are `[String: any
/// Sendable]`, and the key makes the subscript cast safe, so the erasure
/// never surfaces in user code.
public struct MultiKey<Value: Sendable>: Sendable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var description: String { name }
}

/// The results accumulated so far — what step closures receive, and what a
/// successful `repo.run(multi)` returns.
public struct MultiValues: Sendable {
    var storage: [String: any Sendable] = [:]

    /// Typed retrieval, no cast at the call site. Reading a key whose step
    /// hasn't run (or doesn't exist) is a wiring bug — deterministic on
    /// first execution — and traps with the key's name, same policy as
    /// `Container.resolve`. Mistyped keys can't survive to here:
    /// `repo.run(multi)` rejects duplicate step names up front, and a
    /// step's value always matches its own key's type.
    public subscript<T: Sendable>(_ key: MultiKey<T>) -> T {
        guard let raw = storage[key.name] else {
            preconditionFailure("""
            Multi has no result named '\(key.name)' — a step can only read keys of steps ordered before it.
            """)
        }
        guard let value = raw as? T else {
            preconditionFailure("""
            Multi result '\(key.name)' is \(type(of: raw)), not \(T.self) — two MultiKeys share a name with different types.
            """)
        }
        return value
    }
}

/// Which step failed, why, and everything that had completed before it —
/// all of which was rolled back.
public struct MultiFailure: Sendable {
    public let key: String
    public let error: any Error
    public let completed: MultiValues
}

/// The outcome of `repo.run(multi)`: results keyed by step, or the first
/// failure. Step failures arrive here, not as thrown errors — the throw
/// path is reserved for the transaction machinery itself.
public enum MultiResult: Sendable {
    case success(MultiValues)
    case failure(MultiFailure)
}

public struct Multi: Sendable {
    struct Step: Sendable {
        let name: String
        let run: @Sendable (Repo, MultiValues) async throws -> any Sendable
    }

    private(set) var steps: [Step] = []

    public init() {}

    // MARK: Changeset steps

    public func insert<M: Table>(_ key: MultiKey<M>, _ changeset: Changeset<M>) -> Multi {
        adding(key.name) { repo, _ in try await repo.insert(changeset) }
    }

    /// Dependent insert: the changeset is built from earlier results —
    /// `.insert(K.profile) { r in profileChangeset(for: r[K.user]) }`.
    public func insert<M: Table>(
        _ key: MultiKey<M>,
        _ make: @escaping @Sendable (MultiValues) throws -> Changeset<M>
    ) -> Multi {
        adding(key.name) { repo, values in try await repo.insert(make(values)) }
    }

    public func update<M: Table>(_ key: MultiKey<M>, _ changeset: Changeset<M>) -> Multi {
        adding(key.name) { repo, _ in try await repo.update(changeset) }
    }

    public func update<M: Table>(
        _ key: MultiKey<M>,
        _ make: @escaping @Sendable (MultiValues) throws -> Changeset<M>
    ) -> Multi {
        adding(key.name) { repo, values in try await repo.update(make(values)) }
    }

    public func delete<M: Table>(
        _ key: MultiKey<M>,
        _ make: @escaping @Sendable (MultiValues) throws -> M
    ) -> Multi {
        adding(key.name) { repo, values in
            let model = try make(values)
            try await repo.delete(model)
            return model
        }
    }

    // MARK: Arbitrary steps

    /// A named step with an arbitrary body — its return value lands under
    /// `key`. The body runs inside the Multi's transaction with the
    /// transaction repo bound as `Repo.current`, so `Repo.require` inside
    /// participates in it.
    public func run<T: Sendable>(
        _ key: MultiKey<T>,
        _ body: @escaping @Sendable (MultiValues) async throws -> T
    ) -> Multi {
        adding(key.name) { _, values in try await body(values) }
    }

    /// A keyless side-effect step —
    /// `.run { r in try await sendWelcomeEmail(to: r[K.user]) }`. Named
    /// internally by position for failure reporting.
    public func run(
        _ body: @escaping @Sendable (MultiValues) async throws -> Void
    ) -> Multi {
        adding("run#\(steps.count)") { _, values in
            try await body(values)
            return ()
        }
    }

    /// Appends another Multi's steps after this one's (: steps are
    /// values, so composition is data manipulation). Name collisions are
    /// caught by `repo.run(multi)`'s duplicate check.
    public func merging(_ other: Multi) -> Multi {
        var next = self
        next.steps.append(contentsOf: other.steps)
        return next
    }

    private func adding(
        _ name: String,
        _ run: @escaping @Sendable (Repo, MultiValues) async throws -> any Sendable
    ) -> Multi {
        var next = self
        next.steps.append(Step(name: name, run: run))
        return next
    }
}

extension Repo {
    /// Runs every step in one transaction. A step failure rolls the whole
    /// transaction back and returns `.failure` naming the step; the throw
    /// path is reserved for the machinery (connection loss, commit
    /// failure, duplicate step names).
    public func run(_ multi: Multi) async throws -> MultiResult {
        var seen = Set<String>()
        for step in multi.steps {
            guard seen.insert(step.name).inserted else {
                throw HangarError.duplicateMultiStep(name: step.name)
            }
        }

        struct StepFailed: Error {
            let failure: MultiFailure
        }

        do {
            let values = try await transaction { tx in
                var values = MultiValues()
                for step in multi.steps {
                    do {
                        // Ambient access for `run` steps: the
                        // transaction repo is the current repo while a
                        // step executes.
                        let result = try await Repo.with(tx) {
                            try await step.run(tx, values)
                        }
                        values.storage[step.name] = result
                    } catch {
                        throw StepFailed(
                            failure: MultiFailure(key: step.name, error: error, completed: values))
                    }
                }
                return values
            }
            return .success(values)
        } catch let stepFailure as StepFailed {
            return .failure(stepFailure.failure)
        }
    }
}
