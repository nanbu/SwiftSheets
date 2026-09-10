import Foundation

/// A read-only view of a ZIP container's entries, for format detection and codec `canDecode` checks.
package struct ZipInspection: Sendable {
    let archive: ZipArchive

    package init(data: Data) throws { archive = try ZipArchive(data: data) }
    package init(archive: ZipArchive) { self.archive = archive }

    /// "PK\u{03}\u{04}" — the local file header signature.
    package static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B && data[data.startIndex + 2] == 0x03 && data[data.startIndex + 3] == 0x04
    }

    package var entryNames: [String] { archive.entries.keys.sorted() }
    package func contains(_ name: String) -> Bool { archive.contains(name) }
    /// The decompressed bytes of an entry; nil when absent or unreadable.
    package func entry(named name: String) -> Data? { try? archive.read(name) }
}
