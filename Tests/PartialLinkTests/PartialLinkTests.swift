import Foundation
import Testing
import SheetCore
import SheetXLSX
import SheetODS
import SheetNumbers
// Deliberately neither `import SheetCSV` nor `import SwiftSheets`: this target is an application that links only
// what it needs, and everything below has to be reachable from those four products alone (spec Appendix B.44).

/// The facade without the umbrella: a `CodecSet` of three formats opens, inspects, walks and writes them, and
/// refuses the format it lacks by name.
@Suite struct PartialLinkTests {
    static let codecs = CodecSet([XLSXCodec.self, XLSMCodec.self, ODSCodec.self, NumbersCodec.self])

    static func sample() -> Workbook {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.name = "Data"
        ws.append([.text("item"), .text("qty")])
        for i in 1...20 { ws.append([.text("row\(i)"), .integer(i)]) }
        wb.sheets[0] = ws
        return wb
    }

    static func temporary(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-partial-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// The message a refusal carries, or nil when the call went through.
    static func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return String(describing: error) }
    }

    @Test func theSetSaysWhatItHolds() {
        #expect(Self.codecs.formats == [.xlsx, .xlsm, .ods, .numbers])
        #expect(Self.codecs.contains(.numbers))
        #expect(!Self.codecs.contains(.csv))
    }

    /// Every entry point the umbrella has, from bytes and from a file, for each format the set holds.
    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func theThreeFormatsOpenInspectWalkAndWrite(_ format: SheetFormat) throws {
        let data = try Self.codecs.write(Self.sample(), as: format).data

        let read = try Self.codecs.read(data)                       // the format is detected, not named
        #expect(read.workbook.sheets[0].name == "Data")
        #expect(read.workbook.sheets[0]["A1"] == .text("item"))
        #expect(read.workbook.sheets[0]["B21"] == .integer(20))

        let summary = try Self.codecs.inspect(data)
        #expect(summary.format == format)
        #expect(summary.sheets.map(\.name) == ["Data"])

        let reader = try Self.codecs.streamingReader(data: data)
        #expect(reader.format == format)
        var rows = 0
        try reader.forEachRow(inSheet: "Data") { _ in rows += 1 }
        #expect(rows == 21)

        // the same three over a file on disk
        let url = Self.temporary("sample.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.codecs.write(Self.sample(), to: url)
        #expect(try Self.codecs.read(contentsOf: url).workbook.sheets[0]["A2"] == .text("row1"))
        #expect(try Self.codecs.inspect(contentsOf: url).format == format)
        var fromFile = 0
        try Self.codecs.streamingReader(contentsOf: url).forEachRow(inSheet: "Data") { _ in fromFile += 1 }
        #expect(fromFile == 21)

        // and a row-by-row write, read back by the ordinary reader
        let streamed = Self.temporary("streamed.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: streamed.deletingLastPathComponent()) }
        let writer = try Self.codecs.streamingWriter(url: streamed, sheetName: "Rows")
        try writer.append([.text("a"), .integer(1)])
        try writer.append([.text("b"), .integer(2)])
        try writer.close()
        let back = try Self.codecs.read(contentsOf: streamed).workbook
        #expect(back.sheets[0].name == "Rows")
        #expect(back.sheets[0]["B2"] == .integer(2))
    }

    /// The set has no CSV codec, so a text file is not "unrecognised": detection knows what it is, and the refusal
    /// says so and names the product to link.
    @Test func aFormatOutsideTheSetIsRefusedByName() throws {
        let csv = Data("item,qty\napple,3\n".utf8)
        let url = Self.temporary("plain.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try csv.write(to: url)

        let refusals = [
            Self.refusal { _ = try Self.codecs.read(csv) },
            Self.refusal { _ = try Self.codecs.read(contentsOf: url) },
            Self.refusal { _ = try Self.codecs.inspect(csv) },
            Self.refusal { _ = try Self.codecs.streamingReader(data: csv) },
            Self.refusal { _ = try Self.codecs.streamingReader(contentsOf: url) },
            Self.refusal { _ = try Self.codecs.write(Self.sample(), as: .csv) },
            Self.refusal { _ = try Self.codecs.streamingWriter(url: url) },     // the extension asks for CSV
        ]
        for message in refusals {
            let text = try #require(message, "the call must be refused")
            #expect(text.contains(".csv") && text.contains("SheetCSV"), Comment(rawValue: text))
        }
    }
}
