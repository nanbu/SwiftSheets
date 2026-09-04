import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Detection over a file (spec §4.2, Appendix B.39.4): the same verdict as over its bytes, reached without reading
/// the file; one answer that covers what the library will not open; a Numbers document saved as a folder.
@Suite struct DetectionTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    /// Counts what a detector reads from it.
    final class CountingSource: ByteSource, @unchecked Sendable {
        let inner: DataByteSource
        var bytesRead = 0
        init(_ data: Data) { inner = DataByteSource(data) }
        var count: Int { inner.count }
        func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
            bytesRead += range.count
            return try inner.withBytes(in: range, body)
        }
    }

    /// Every fixture answers the same from its file as from its bytes.
    @Test func aFileAndItsBytesGiveTheSameVerdict() throws {
        let walker = FileManager.default.enumerator(at: Self.fixtures, includingPropertiesForKeys: [.isRegularFileKey])!
        var checked = 0
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["xlsx", "xlsm", "ods", "numbers", "csv", "tsv", "xls", "zip"].contains(ext) else { continue }
            let data = try Data(contentsOf: url)
            #expect(try SheetFormat.detect(contentsOf: url) == SheetFormat.detect(from: data, filename: url.lastPathComponent), "\(url.lastPathComponent)")
            #expect(try SheetFormat.probe(contentsOf: url) == SheetFormat.probe(data, filename: url.lastPathComponent), "\(url.lastPathComponent)")
            checked += 1
        }
        #expect(checked > 40, "the corpus was walked")
    }

    /// Detection reads the head, the directory and one small entry — not the file. A five-megabyte workbook
    /// costs a few kilobytes to identify.
    @Test func detectionDoesNotReadTheFile() throws {
        var wb = Workbook()
        for r in 0..<40_000 { wb.sheets[0].append([.integer(r), .text("row \(r) with some words in it"), .number(0.5)]) }
        let data = try wb.data(as: .xlsx)
        #expect(data.count > 500_000)
        let source = CountingSource(data)
        #expect(try SheetFormat.detect(source: source) == .xlsx)
        #expect(source.bytesRead < 16_384, "read \(source.bytesRead) of \(data.count) bytes")
        let csv = CountingSource(Data(String(repeating: "a,b,c\n", count: 500_000).utf8))
        #expect(try SheetFormat.detect(source: csv) == .csv)
        #expect(csv.bytesRead <= 64 * 1024 + 4, "the signature and one text window")
    }

    /// One answer for everything: the format, or why the file will not open, or nothing known.
    @Test func theProbeAnswersInOneCall() throws {
        func probe(_ name: String) throws -> FormatProbe { try SheetFormat.probe(contentsOf: Self.fixtures.appendingPathComponent(name)) }
        #expect(try probe("styled.xlsx") == .spreadsheet(.xlsx))
        #expect(try probe("preservation/with-vba.xlsm") == .spreadsheet(.xlsm))
        #expect(try probe("ods/styled.ods") == .spreadsheet(.ods))
        #expect(try probe("numbers/test-1.numbers") == .spreadsheet(.numbers))
        #expect(try probe("encrypted/agile.xlsx") == .unopenable(.encryptedOOXML))
        #expect(try probe("encrypted/legacy.xls") == .unopenable(.legacyCompoundFile))
        #expect(try probe("encrypted/protected.ods") == .unopenable(.encryptedODF))
        #expect(SheetFormat.probe(Data("a,b\n1,2\n".utf8)) == .spreadsheet(.csv))
        #expect(SheetFormat.probe(Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00])) == .unrecognized)
        #expect(FormatProbe.spreadsheet(.ods).format == .ods && FormatProbe.unrecognized.format == nil)
    }

    /// A password-protected Numbers document is named for what it is.
    @Test func anEncryptedNumbersDocumentIsNamed() throws {
        let zip = ZipWriter()
        zip.add(".iwph", Data([1, 2, 3]), stored: true)
        zip.add("Index/Document.iwa", Data([0]), stored: true)
        let data = zip.finish()
        #expect(SheetFormat.probe(data) == .unopenable(.encryptedNumbers))
        #expect(throws: SheetError.unsupportedFeature(UnopenableInput.encryptedNumbers.reason)) { _ = try Workbook(data: data) }
    }

    /// Text is judged as bytes now; the verdicts have not moved.
    @Test func textSniffingJudgesBytes() {
        #expect(TextEncodingSniffer.looksLikeText(Data()))
        #expect(TextEncodingSniffer.looksLikeText(Data("名前,値\n1,2\r\n\t".utf8)))
        #expect(TextEncodingSniffer.looksLikeText(Data([0xEF, 0xBB, 0xBF] + Array("bom\n".utf8))))
        #expect(!TextEncodingSniffer.looksLikeText(Data([0x00, 0x01, 0x02])))
        #expect(!TextEncodingSniffer.looksLikeText(Data([0xC3])), "a cut-off sequence in a whole file is not text")
        #expect(!TextEncodingSniffer.looksLikeText(Data("a\u{01}b".utf8)), "control characters are not text")
        // UTF-16 with a BOM, both orders, with a surrogate pair
        let le = Data([0xFF, 0xFE] + "a😀\n".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        let be = Data([0xFE, 0xFF] + "a😀\n".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] })
        #expect(TextEncodingSniffer.looksLikeText(le) && TextEncodingSniffer.looksLikeText(be))
        #expect(!TextEncodingSniffer.looksLikeText(Data([0xFF, 0xFE, 0x01, 0x00])), "a UTF-16 control character is not text")
        // a multi-byte character cut by the 64 KiB window is a boundary, not a fault
        var big = Data(String(repeating: "x", count: 64 * 1024 - 1).utf8)
        big.append(contentsOf: "日".utf8)
        #expect(TextEncodingSniffer.looksLikeText(big))
    }

    /// A Numbers document saved as a folder: detected, read and inspected like its single-file twin.
    @Test func aNumbersFolderBundleIsDetectedAndRead() throws {
        let single = Self.fixtures.appendingPathComponent("numbers/test-1.numbers")
        let data = try Data(contentsOf: single)
        let archive = try ZipArchive(data: data)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-bundle-\(UUID().uuidString)/folder.numbers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let index = ZipWriter()
        for name in archive.names where !name.hasSuffix("/") {
            let bytes = try archive.read(name)
            if name.hasPrefix("Index/") {
                index.add(name, bytes, stored: true)
            } else {
                let target = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target)
            }
        }
        try index.finish().write(to: folder.appendingPathComponent("Index.zip"))

        #expect(try SheetFormat.detect(contentsOf: folder) == .numbers)
        #expect(try SheetFormat.probe(contentsOf: folder) == .spreadsheet(.numbers))
        let fromFolder = try Workbook(contentsOf: folder)
        let fromFile = try Workbook(contentsOf: single)
        #expect(fromFolder.sheets.map(\.name) == fromFile.sheets.map(\.name))
        for (a, b) in Swift.zip(fromFolder.sheets, fromFile.sheets) { #expect(a.tables.map(\.cells) == b.tables.map(\.cells), "\(a.name)") }
        #expect(fromFolder.sourceInfo?.version == fromFile.sourceInfo?.version, "Metadata is read from the folder too")
        let summary = try Workbook.inspect(contentsOf: folder)
        #expect(summary.format == .numbers && summary.sheets.map(\.name) == fromFile.sheets.map(\.name))
        // a folder that is not a bundle is nothing known
        let plain = folder.deletingLastPathComponent()
        #expect(try SheetFormat.detect(contentsOf: plain) == nil)
        #expect(throws: SheetError.unrecognizedFormat) { _ = try Workbook(contentsOf: plain) }
    }
}
