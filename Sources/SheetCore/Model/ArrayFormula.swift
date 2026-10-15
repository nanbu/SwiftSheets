import Foundation

/// Provenance participates in binding checks, but not in workbook value equality or hashing.
/// Always use `matches(_:)` to test source identity; `==` deliberately ignores this bookkeeping.
package struct MetadataSourceIdentity: Sendable, Hashable {
    private let identifier: UUID?
    package init() { identifier = nil }
    private init(identifier: UUID) { self.identifier = identifier }
    package static func fresh() -> Self { Self(identifier: UUID()) }
    package func matches(_ other: Self) -> Bool {
        guard let identifier else { return false }
        return identifier == other.identifier
    }
    package static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }
    package func hash(into hasher: inout Hasher) {}
}

/// Source indices into XLSX's opaque cell and value metadata blocks. Their records remain in the source part.
package struct XLSXCellMetadata: Sendable, Hashable {
    package var cell: String?
    package var value: String?
    package init(cell: String? = nil, value: String? = nil) { self.cell = cell; self.value = value }
}
