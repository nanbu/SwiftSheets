import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The container layer on its own (spec Appendix B.39): ZIP64 both ways, bytes read from a file in pieces rather
/// than mapped whole, entries expanded a piece at a time, and the shapes of a decompression bomb turned away.
@Suite struct ZipTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static func temporary(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - ZIP64

    /// An archive Info-ZIP wrote with ZIP64 structures forced on: a ZIP64 end-of-central-directory record, its
    /// locator, and ZIP64 extra fields on every entry. Nothing in it is large; the shape is what matters.
    @Test func readsAZip64ArchiveSomebodyElseWrote() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("zip/infozip-zip64.zip"))
        #expect(data.contains(Data([0x50, 0x4b, 0x06, 0x06])), "the fixture really carries the ZIP64 record")
        let zip = try ZipArchive(data: data)
        #expect(zip.names.contains("src/hello.txt") && zip.names.contains("src/zeros.bin"))
        let hello = String(decoding: try zip.read("src/hello.txt"), as: UTF8.self)
        #expect(hello.hasPrefix("hello from a zip64 archive"))
        #expect(try zip.read("src/zeros.bin") == Data(count: 256))
    }

    /// Our own writer, told to use the ZIP64 bookkeeping for every entry: what it writes, it reads.
    @Test func writesAndReadsItsOwnZip64Form() throws {
        let writer = ZipWriter()
        writer.forceZip64 = true
        writer.add("a.txt", Data("alpha".utf8), stored: true)
        writer.add("b.txt", Data(String(repeating: "beta ", count: 500).utf8))
        try writer.beginEntry("streamed.txt")
        for i in 0..<100 { try writer.write("line \(i)\n") }
        try writer.endEntry()
        let data = writer.finish()
        #expect(data.contains(Data([0x50, 0x4b, 0x06, 0x06])), "a ZIP64 end-of-central-directory record is written")
        let zip = try ZipArchive(data: data)
        #expect(zip.names == ["a.txt", "b.txt", "streamed.txt"])
        #expect(try zip.read("a.txt") == Data("alpha".utf8))
        #expect(try zip.read("b.txt") == Data(String(repeating: "beta ", count: 500).utf8))
        #expect(String(decoding: try zip.read("streamed.txt"), as: UTF8.self).hasSuffix("line 99\n"))
    }

    /// A streamed entry in an ordinary (not forced) archive: the reserved ZIP64 extra field holds the same
    /// numbers as the 32-bit fields, and a reader that ignores it reads the entry all the same.
    @Test func aStreamedEntryIsReadableWithAndWithoutItsExtraField() throws {
        let writer = ZipWriter()
        try writer.beginEntry("s.txt")
        try writer.write(String(repeating: "streamed\n", count: 1000))
        try writer.endEntry()
        let data = writer.finish()
        #expect(!data.contains(Data([0x50, 0x4b, 0x06, 0x06])), "small sizes need no ZIP64 record")
        #expect(try ZipArchive(data: data).read("s.txt").count == 9000)
    }

    /// More entries than a plain ZIP can count is the ZIP64 case a test can afford to make for real.
    @Test func moreThan65535EntriesForceTheZip64Records() throws {
        let writer = ZipWriter()
        for i in 0..<65_540 { writer.add("e\(i)", Data([UInt8(i & 0xff)]), stored: true) }
        let data = writer.finish()
        let zip = try ZipArchive(data: data)
        #expect(zip.entries.count == 65_540)
        #expect(try zip.read("e65539") == Data([UInt8(65_539 & 0xff)]))
        #expect(try zip.read("e0") == Data([0]))
    }

    // MARK: - Sources and streams

    /// A file read in pieces answers exactly as the same file in memory does.
    @Test func aFileReadInPiecesMatchesTheSameFileInMemory() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("styled.xlsx"))
        let url = Self.temporary("styled.xlsx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try data.write(to: url)
        let mapped = try ZipArchive(data: data)
        let file = try ZipArchive(source: try FileByteSource(url: url))
        #expect(mapped.names == file.names)
        for name in mapped.names where !name.hasSuffix("/") {
            #expect(try mapped.read(name) == file.read(name), "\(name)")
        }
    }

    /// A directory is not a file; the source says so instead of reading nothing.
    @Test func aDirectoryIsRefusedAsASource() {
        #expect(throws: SheetError.self) { try FileByteSource(url: FileManager.default.temporaryDirectory) }
    }

    /// Piece by piece is the same bytes as all at once, and no piece is larger than the reader promised.
    @Test func anEntryExpandedInPiecesIsTheSameBytes() throws {
        let text = Data((0..<400_000).map { UInt8(($0 * 7) % 251) })   // incompressible enough to span pieces
        let writer = ZipWriter()
        writer.add("big.bin", text)
        writer.add("stored.bin", text, stored: true)
        let zip = try ZipArchive(data: writer.finish())
        for name in ["big.bin", "stored.bin"] {
            let stream = try zip.stream(name)
            var out = Data()
            while let piece = try stream.next() { out.append(piece) }
            #expect(out == text, "\(name)")
            #expect(stream.largestPiece <= ZipEntryStream.pieceSize * 4, "\(name)")
        }
    }

    /// An entry copied compressed comes out byte for byte, and the copy did not go through the compressor.
    @Test func aCompressedEntryCanBeCopiedWithoutExpandingIt() throws {
        let source = try Data(contentsOf: Self.fixtures.appendingPathComponent("preservation/charts-and-friends.xlsx"))
        let zip = try ZipArchive(data: source)
        let writer = ZipWriter()
        for name in zip.names {
            let (payload, entry) = try zip.compressed(name)
            writer.addCompressed(name, payload: payload, method: entry.method, crc: entry.crc32, uncompressedSize: entry.uncompressedSize)
        }
        let copy = try ZipArchive(data: writer.finish())
        #expect(copy.names == zip.names)
        for name in zip.names {
            #expect(try copy.compressed(name).payload == zip.compressed(name).payload, "\(name): the folded bytes themselves are the same")
            #expect(try copy.read(name) == zip.read(name), "\(name)")
        }
    }

    // MARK: - Bombs

    /// Two entries sharing bytes is how a small file claims to be a large one. The directory is refused.
    @Test func overlappingEntriesAreRefused() throws {
        let writer = ZipWriter()
        writer.add("one.txt", Data(String(repeating: "x", count: 1000).utf8))
        let data = writer.finish()
        // duplicate the one central-directory entry under another name, pointing at the same local header
        let cdStart = data.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
        let eocd = data.range(of: Data([0x50, 0x4b, 0x05, 0x06]))!.lowerBound
        var entry = Data(data[cdStart..<eocd])
        entry.replaceSubrange(46..<49, with: Data("two".utf8))
        var forged = Data(data[..<cdStart])
        forged.append(Data(data[cdStart..<eocd])); forged.append(entry)
        var tail = Data(data[eocd...])
        tail[8] = 2; tail[10] = 2                                              // two entries
        tail.replaceSubrange(12..<16, with: Zip.le32(UInt32(entry.count * 2)))
        forged.append(tail)
        let error = #expect(throws: SheetError.self) { try ZipArchive(data: forged) }
        if case .corruptedContainer(let detail)? = error { #expect(detail.contains("overlap")) }
    }

    /// A run of zeros folds a thousandfold; past the ratio a caller allows, the entry is not expanded at all.
    @Test func anEntryThatExpandsTooFarIsRefusedBeforeItIsExpanded() throws {
        let zeros = Data(count: 4 << 20)
        let writer = ZipWriter()
        writer.add("zeros.bin", zeros)
        let data = writer.finish()
        #expect(data.count < zeros.count / 500)
        // the default floor is 16 MiB, so this one is allowed; lower the floor and the ratio, and it is not
        #expect(throws: Never.self) { try ZipArchive(data: data) }
        var tight = ZipLimits()
        tight.ratioFloor = 1 << 20
        tight.maxCompressionRatio = 100
        let error = #expect(throws: SheetError.self) { try ZipArchive(data: data, limits: tight) }
        if case .corruptedContainer(let detail)? = error { #expect(detail.contains("fold")) }
    }

    /// The sum of what the entries declare is bounded too, however innocent each one looks.
    @Test func aPackageThatWouldExpandPastTheBudgetIsRefused() throws {
        let writer = ZipWriter()
        for i in 0..<8 { writer.add("part\(i)", Data(count: 1 << 20)) }
        let data = writer.finish()
        var tight = ZipLimits()
        tight.maxExpandedBytes = 4 << 20
        #expect(throws: SheetError.self) { try ZipArchive(data: data, limits: tight) }
        tight.maxExpandedBytes = 8 << 20
        #expect(throws: Never.self) { try ZipArchive(data: data, limits: tight) }
    }

    @Test func tooManyEntriesAreRefused() throws {
        let writer = ZipWriter()
        for i in 0..<50 { writer.add("e\(i)", Data([1]), stored: true) }
        let data = writer.finish()
        var tight = ZipLimits(); tight.maxEntries = 10
        #expect(throws: SheetError.self) { try ZipArchive(data: data, limits: tight) }
    }

    /// A stream that keeps producing past the size its entry declares is stopped there, not obeyed.
    @Test func aStreamThatOverrunsItsDeclaredSizeIsCorrupt() throws {
        let text = Data(String(repeating: "overrun ", count: 10_000).utf8)
        let packed = try #require(Deflate.compress(text))
        #expect(throws: SheetError.self) { try Deflate.decompress(packed, expectedSize: text.count / 2) }
        let decoder = try DeflateDecoder(expectedSize: text.count / 2)
        let out = try decoder.decode(packed)
        #expect(out.count == text.count / 2, "expanded exactly to the declared size and no further")
        #expect(decoder.produced == text.count / 2)
        #expect(throws: SheetError.self) { _ = try decoder.decode(Data([0])) }
    }

    /// The limits reach the readers through `ReadOptions`.
    @Test func readOptionsCarryTheLimitsToTheReader() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let data = try wb.data(as: .xlsx)
        var options = ReadOptions()
        options.limits.maxEntries = 2
        #expect(throws: SheetError.self) { try Workbook.read(data, options: options) }
        #expect(throws: Never.self) { try Workbook.read(data) }
    }

    /// The cell ceiling is the caller's now: nothing by default, and whatever they say when they say it.
    @Test func theCellCeilingIsOffByDefaultAndOnWhenAsked() throws {
        #expect(ReadOptions().cellLimit == Int.max)
        #expect(ReadOptions(cellLimit: 10).cellLimit == 10)
    }
}
