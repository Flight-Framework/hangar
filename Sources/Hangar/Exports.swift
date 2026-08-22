// A Hangar user writes @Entity types and calls repo.all(...) against a
// PostgresClient — one import covers the whole surface, including the
// PostgresNIO types that appear in Hangar's own API (PostgresClient,
// PostgresRow) and in macro-generated code, and the changeset layer
// (Changeset, ValidationRule, TableModel) that repo.insert/update and
// Multi consume (design §11.2).
@_exported import Changesets
@_exported import PostgresNIO
