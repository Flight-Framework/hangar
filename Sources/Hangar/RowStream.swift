import PostgresNIO

/// A lazily-decoded result set: rows arrive from the server and decode one
/// at a time, so memory stays flat regardless of how many there are.
///
/// Obtained from `repo.stream(query) {... }`, and valid only inside that
/// closure — the connection is leased for the stream's lifetime, which is
/// what bounds it. Escaping the sequence and iterating later is a use after
/// the lease is returned.
public struct PostgresRowStream<Element: Sendable>: AsyncSequence, Sendable {
    let rows: PostgresRowSequence
    let decode: @Sendable (PostgresRow) throws -> Element

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: PostgresRowSequence.AsyncIterator
        let decode: @Sendable (PostgresRow) throws -> Element

        public mutating func next() async throws -> Element? {
            guard let row = try await base.next() else { return nil }
            return try decode(row)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: rows.makeAsyncIterator(), decode: decode)
    }
}
