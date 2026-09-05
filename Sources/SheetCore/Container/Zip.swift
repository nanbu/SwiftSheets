import Foundation

/// What a reader will put up with from a container before calling it hostile (spec Appendix B.39).
///
/// A ZIP entry announces its own expanded size, and the reader believes it exactly — never more, never less — so
/// memory is bounded by what the file declares. These limits bound the declarations themselves: a package that
/// says it holds a terabyte is not a spreadsheet, however small it is on disk. Every one of them can be raised by a
/// caller who knows their file, through `ReadOptions.limits`.
public struct ZipLimits: Sendable, Hashable {
    /// The most entries a package may declare. A workbook has a part per sheet plus a handful of others; a hundred
    /// thousand is far past any real document and far short of what would exhaust memory in a directory alone.
    public var maxEntries = 100_000
    /// The most bytes all entries together may expand to (16 GiB). The working size of a workbook is a few
    /// hundred bytes per cell, so a package expanding past this could not be held in memory anyway.
    public var maxExpandedBytes = 16 << 30
    /// The most an entry may expand relative to its compressed bytes, once it is large enough to matter
    /// (`ratioFloor`). Spreadsheet XML folds ten- to fifty-fold; a thousand-fold is a run of zeros.
    public var maxCompressionRatio = 1_000
    /// Entries smaller than this (expanded) are not ratio-checked: a tiny entry cannot hurt, and a tiny one folds
    /// unpredictably.
    public var ratioFloor = 16 << 20

    public init(maxEntries: Int = 100_000, maxExpandedBytes: Int = 16 << 30, maxCompressionRatio: Int = 1_000, ratioFloor: Int = 16 << 20) {
        self.maxEntries = maxEntries; self.maxExpandedBytes = maxExpandedBytes
        self.maxCompressionRatio = maxCompressionRatio; self.ratioFloor = ratioFloor
    }

    public static let `default` = ZipLimits()
}

/// ZIP container reader: central directory → entries; stored (0) and deflate (8); ZIP64; no encryption.
///
/// Bytes come from a `ByteSource`, so the file may be in memory, mapped, or read in pieces from disk, and the
/// reader never asks for more of it than the directory and the entry in hand. Every length the file states about
/// itself is checked against the file before it is used, entries may not overlap, and what the whole package would
/// expand to is bounded (`ZipLimits`) — the shapes a decompression bomb takes.
package struct ZipArchive: Sendable {
    package struct Entry: Sendable, Hashable {
        package let name: String
        package let method: UInt16
        package let crc32: UInt32
        package let compressedSize: Int
        package let uncompressedSize: Int
        package let localHeaderOffset: Int
        /// Length of the name in the central directory, for the overlap check.
        let nameLength: Int
        package var isDirectory: Bool { name.hasSuffix("/") }
    }

    package let source: any ByteSource
    package let entries: [String: Entry]
    /// Entry names in central-directory order — the order the writer put them in.
    package let names: [String]
    package let limits: ZipLimits

    package init(data: Data, limits: ZipLimits = .default) throws {
        try self.init(source: DataByteSource(data), limits: limits)
    }

    package init(source: any ByteSource, limits: ZipLimits = .default) throws {
        self.source = source
        self.limits = limits
        let total = source.count
        guard total >= 22 else { throw SheetError.corruptedContainer(detail: "file too small") }

        // the end-of-central-directory record is within the last 64 KiB + 22 bytes (the comment's maximum); a
        // package without a comment — every spreadsheet — has it in the last kilobyte, so that is read first
        var tailStart = Swift.max(0, total - 1024)
        if try !source.withBytes(in: tailStart..<total, { ZipArchive.containsEndRecord($0) }) {
            tailStart = Swift.max(0, total - 22 - 65535)
        }
        let (directory, count) = try source.withBytes(in: tailStart..<total) { tail -> (Range<Int>, Int) in
            let b = tail.bindMemory(to: UInt8.self)
            var eocd = -1
            var i = b.count - 22
            while i >= 0 {
                if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
                i -= 1
            }
            guard eocd >= 0 else { throw SheetError.corruptedContainer(detail: "end of central directory not found") }
            var count = Int(Zip.u16(b, eocd + 10))
            var cdSize = Int(Zip.u32(b, eocd + 12))
            var cdOffset = Int(Zip.u32(b, eocd + 16))
            // ZIP64: a locator sits just before the record, and the real numbers are in the record it points at
            if eocd >= 20, Zip.u32(b, eocd - 20) == 0x0706_4b50 {
                let recordOffset = Int(Zip.u64(b, eocd - 20 + 8))
                guard recordOffset >= 0, recordOffset + 56 <= total else { throw SheetError.corruptedContainer(detail: "ZIP64 end of central directory lies outside the file") }
                let record = try source.bytes(in: recordOffset..<(recordOffset + 56))
                let r = [UInt8](record)
                guard Zip.u32(r, 0) == 0x0606_4b50 else { throw SheetError.corruptedContainer(detail: "bad ZIP64 end of central directory") }
                count = Int(Zip.u64(r, 32))
                cdSize = Int(Zip.u64(r, 40))
                cdOffset = Int(Zip.u64(r, 48))
            } else if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
                throw SheetError.corruptedContainer(detail: "ZIP64 markers without a ZIP64 record")
            }
            guard count >= 0, cdSize >= 0, cdOffset >= 0, cdOffset + cdSize <= total else { throw SheetError.corruptedContainer(detail: "corrupt central directory") }
            return (cdOffset..<(cdOffset + cdSize), count)
        }
        guard count <= limits.maxEntries else {
            throw SheetError.corruptedContainer(detail: "the package declares \(count) entries, above the limit of \(limits.maxEntries)")
        }

        var entries: [String: Entry] = [:]
        var names: [String] = []
        entries.reserveCapacity(count)
        names.reserveCapacity(count)
        var expanded = 0
        try source.withBytes(in: directory) { cd in
            let bytes = cd.bindMemory(to: UInt8.self)
            var p = 0
            for _ in 0..<count {
                guard p + 46 <= bytes.count, Zip.u32(bytes, p) == 0x0201_4b50 else { throw SheetError.corruptedContainer(detail: "bad central directory entry") }
                let method = Zip.u16(bytes, p + 10), crc = Zip.u32(bytes, p + 16)
                var csize = Int(Zip.u32(bytes, p + 20)), usize = Int(Zip.u32(bytes, p + 24))
                let nameLen = Int(Zip.u16(bytes, p + 28)), extraLen = Int(Zip.u16(bytes, p + 30)), commentLen = Int(Zip.u16(bytes, p + 32))
                var localOffset = Int(Zip.u32(bytes, p + 42))
                // the header's own lengths are attacker-controlled: every slice below must be inside the buffer
                guard p + 46 + nameLen + extraLen + commentLen <= bytes.count else { throw SheetError.corruptedContainer(detail: "central directory entry runs past the end of the file") }
                let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[(p + 46)..<(p + 46 + nameLen)]), as: UTF8.self)
                // ZIP64: a field at its maximum is a placeholder for the 64-bit value in the extra field
                if usize == 0xFFFF_FFFF || csize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                    var q = p + 46 + nameLen
                    let end = q + extraLen
                    var found = false
                    while q + 4 <= end {
                        let id = Zip.u16(bytes, q), size = Int(Zip.u16(bytes, q + 2))
                        guard q + 4 + size <= end else { throw SheetError.corruptedContainer(detail: "extra field runs past its entry") }
                        if id == 0x0001 {
                            var f = q + 4
                            func take() throws -> Int {
                                guard f + 8 <= q + 4 + size else { throw SheetError.corruptedContainer(detail: "ZIP64 extra field too short") }
                                defer { f += 8 }
                                let v = Zip.u64(bytes, f)
                                guard v <= UInt64(Int.max) else { throw SheetError.corruptedContainer(detail: "ZIP64 value out of range") }
                                return Int(v)
                            }
                            if usize == 0xFFFF_FFFF { usize = try take() }
                            if csize == 0xFFFF_FFFF { csize = try take() }
                            if localOffset == 0xFFFF_FFFF { localOffset = try take() }
                            found = true
                            break
                        }
                        q += 4 + size
                    }
                    guard found else { throw SheetError.corruptedContainer(detail: "ZIP64 placeholder without a ZIP64 extra field") }
                }
                guard localOffset + 30 <= total else { throw SheetError.corruptedContainer(detail: "local header offset past the end of the file") }
                guard csize >= 0, usize >= 0, localOffset + 30 + nameLen + csize <= total else { throw SheetError.corruptedContainer(detail: "entry \(name) runs past the end of the file") }
                if usize >= limits.ratioFloor, csize > 0, usize / csize > limits.maxCompressionRatio {
                    throw SheetError.corruptedContainer(detail: "entry \(name) claims to expand \(usize / csize)-fold, above the limit of \(limits.maxCompressionRatio)")
                }
                expanded += usize
                guard expanded <= limits.maxExpandedBytes else {
                    throw SheetError.corruptedContainer(detail: "the package would expand to more than \(limits.maxExpandedBytes) bytes")
                }
                let entry = Entry(name: name, method: method, crc32: crc, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: localOffset, nameLength: nameLen)
                if entries.updateValue(entry, forKey: name) == nil { names.append(name) }
                p += 46 + nameLen + extraLen + commentLen
            }
        }
        // entries may not share bytes: a directory whose entries point into one another is how a small file
        // pretends to be a large one (and how a reader is made to expand the same bytes many times over)
        let byOffset = entries.values.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for i in 1..<Swift.max(1, byOffset.count) {
            let previous = byOffset[i - 1]
            let end = previous.localHeaderOffset + 30 + previous.nameLength + previous.compressedSize
            guard byOffset[i].localHeaderOffset >= end else {
                throw SheetError.corruptedContainer(detail: "entries \(previous.name) and \(byOffset[i].name) overlap")
            }
        }
        self.entries = entries
        self.names = names
    }

    package func contains(_ name: String) -> Bool { entries[name] != nil }

    static func containsEndRecord(_ tail: UnsafeRawBufferPointer) -> Bool {
        let b = tail.bindMemory(to: UInt8.self)
        var i = b.count - 22
        while i >= 0 {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 { return true }
            i -= 1
        }
        return false
    }

    /// Where an entry's compressed bytes start: past its local header, whose own name / extra lengths may differ
    /// from the central directory's.
    package func dataRange(of e: Entry) throws -> Range<Int> {
        let h = e.localHeaderOffset
        try source.check(h..<(h + 30), what: "local header of \(e.name)")
        let start = try source.withBytes(in: h..<(h + 30)) { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard Zip.u32(bytes, 0) == 0x0403_4b50 else { throw SheetError.corruptedContainer(detail: "bad local header for \(e.name)") }
            let nameLen = Int(Zip.u16(bytes, 26)), extraLen = Int(Zip.u16(bytes, 28))
            return h + 30 + nameLen + extraLen
        }
        guard e.compressedSize >= 0, start + e.compressedSize <= source.count else { throw SheetError.corruptedContainer(detail: "truncated data for \(e.name)") }
        return start..<(start + e.compressedSize)
    }

    /// The expanded bytes of an entry, whole.
    package func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw SheetError.corruptedContainer(detail: "missing part \(name)") }
        let range = try dataRange(of: e)
        switch e.method {
        case 0:
            guard e.uncompressedSize == e.compressedSize else { throw SheetError.corruptedContainer(detail: "stored entry \(name) declares two different sizes") }
            return try source.bytes(in: range)
        case 8:
            return try source.withBytes(in: range) { raw in try Deflate.decompress(raw, expectedSize: e.uncompressedSize) }
        default: throw SheetError.corruptedContainer(detail: "unsupported compression method \(e.method) for \(name)")
        }
    }

    /// The entry's bytes as they lie in the file — still compressed — with what a writer needs to copy them into
    /// another package without expanding them: byte for byte, and without the cost of folding them again.
    package func compressed(_ name: String) throws -> (payload: Data, entry: Entry) {
        guard let e = entries[name] else { throw SheetError.corruptedContainer(detail: "missing part \(name)") }
        guard e.method == 0 || e.method == 8 else { throw SheetError.corruptedContainer(detail: "unsupported compression method \(e.method) for \(name)") }
        return (try source.bytes(in: try dataRange(of: e)), e)
    }

    /// An entry expanded piece by piece: `next()` hands back up to about a megabyte at a time and nothing of the
    /// entry is held beyond that. For the reader that walks a sheet without ever holding its XML.
    package func stream(_ name: String) throws -> ZipEntryStream {
        guard let e = entries[name] else { throw SheetError.corruptedContainer(detail: "missing part \(name)") }
        return try ZipEntryStream(archive: self, entry: e, range: try dataRange(of: e))
    }
}

/// One entry being expanded in pieces. Not `Sendable`: a stream has a position.
package final class ZipEntryStream {
    /// How much compressed input is read from the source per turn, and roughly how much expanded output a turn yields.
    package static let pieceSize = 256 * 1024

    private let archive: ZipArchive
    private let entry: ZipArchive.Entry
    private let range: Range<Int>
    private var position: Int
    private let decoder: DeflateDecoder?
    private var done = false
    /// The most expanded bytes handed out from one call so far — what a caller can hold at most.
    package private(set) var largestPiece = 0

    init(archive: ZipArchive, entry: ZipArchive.Entry, range: Range<Int>) throws {
        self.archive = archive; self.entry = entry; self.range = range; position = range.lowerBound
        switch entry.method {
        case 0:
            guard entry.uncompressedSize == entry.compressedSize else { throw SheetError.corruptedContainer(detail: "stored entry \(entry.name) declares two different sizes") }
            decoder = nil
        case 8: decoder = try DeflateDecoder(expectedSize: entry.uncompressedSize)
        default: throw SheetError.corruptedContainer(detail: "unsupported compression method \(entry.method) for \(entry.name)")
        }
    }

    package var name: String { entry.name }
    package var expectedSize: Int { entry.uncompressedSize }

    /// The next piece, or nil when the entry is exhausted.
    package func next() throws -> Data? {
        guard !done else { return nil }
        guard let decoder else {
            let end = Swift.min(position + ZipEntryStream.pieceSize * 4, range.upperBound)
            guard position < end else { done = true; return nil }
            let piece = try archive.source.bytes(in: position..<end)
            position = end
            largestPiece = Swift.max(largestPiece, piece.count)
            return piece
        }
        while true {
            if decoder.finished {
                try decoder.finish()
                done = true
                return nil
            }
            let out: Data
            if position < range.upperBound {
                let end = Swift.min(position + ZipEntryStream.pieceSize, range.upperBound)
                out = try archive.source.withBytes(in: position..<end) { try decoder.decode($0) }
                position = end
            } else {
                // the compressed bytes are exhausted: whatever the decoder still holds comes out now
                out = try decoder.drain()
                if out.isEmpty {
                    try decoder.finish()   // throws when the entry stopped short of its declared size
                    done = true
                    return nil
                }
            }
            if !out.isEmpty {
                largestPiece = Swift.max(largestPiece, out.count)
                return out
            }
        }
    }
}

package enum Zip {
    package static func u16<C: RandomAccessCollection>(_ b: C, _ i: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
    package static func u32<C: RandomAccessCollection>(_ b: C, _ i: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    package static func u64<C: RandomAccessCollection>(_ b: C, _ i: Int) -> UInt64 where C.Element == UInt8, C.Index == Int {
        UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32
    }
    package static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    package static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }
    package static func le64(_ v: UInt64) -> Data { le32(UInt32(truncatingIfNeeded: v)) + le32(UInt32(truncatingIfNeeded: v >> 32)) }
}
