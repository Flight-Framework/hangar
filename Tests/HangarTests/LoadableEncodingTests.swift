import Foundation
import Testing

@testable import Hangar

/// `Loadable` encodes so a preloaded model can be serialized without a
/// hand-written mirror type.
@Suite("Loadable JSON encoding")
struct LoadableEncodingTests {

    private struct Row: Encodable {
        var name: String
        var tags: Loadable<[String]>
    }

    private func json(_ row: Row) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(row), as: UTF8.self)
    }

    @Test("a loaded association encodes as its value")
    func loadedEncodesValue() throws {
        #expect(try json(Row(name: "a", tags: .loaded(["x", "y"]))) == #"{"name":"a","tags":["x","y"]}"#)
    }

    @Test("loaded-and-empty is an empty array, not null")
    func emptyIsNotNull() throws {
        #expect(try json(Row(name: "a", tags: .loaded([]))) == #"{"name":"a","tags":[]}"#)
    }

    @Test("an unloaded association encodes as null")
    func notLoadedEncodesNull() throws {
        #expect(
            try json(Row(name: "a", tags: .notLoaded(association: "tags")))
                == #"{"name":"a","tags":null}"#)
    }

    @Test("there is no Decodable, by design")
    func noDecodable() {
        // A compile-time contract, asserted at runtime as documentation: on
        // the wire `null` cannot separate "not preloaded" from "preloaded and
        // genuinely nothing there", so `Loadable` refuses to guess. Models go
        // out as JSON; what comes back in is a request type of its own.
        #expect(!(Loadable<[String]>.self is any Decodable.Type))
    }
}
