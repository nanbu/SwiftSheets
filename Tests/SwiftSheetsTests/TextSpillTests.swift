import Foundation
import Testing
@testable import SheetCore

/// Text spilled to disk comes back byte for byte, and the streaming compressor takes pieces of any size.
@Suite struct TextSpillTests {
    @Test func aSpilledBodyComesBackIntact() throws {
        let spill = TextSpill()
        var expected = Data()
        var n = 0
        while expected.count < 40 << 20 {
            let line = "<row r=\"\(n)\"><c>\(String(repeating: "x", count: n % 500))日本</c></row>\n"
            spill.write(line)
            expected.append(contentsOf: line.utf8)
            n += 1
        }
        var back = Data()
        try spill.forEachPiece { back.append($0) }
        #expect(back.count == expected.count)
        #expect(back == expected)
        #expect(spill.count == expected.count)
    }

    @Test func theStreamingCompressorTakesLargePieces() throws {
        let piece = Data((0..<(3 << 20)).map { UInt8(($0 * 31) % 251) })
        let encoder = try DeflateEncoder()
        var packed = Data()
        for _ in 0..<5 { packed += try encoder.encode(piece) }
        packed += try encoder.finish()
        var whole = Data()
        for _ in 0..<5 { whole += piece }
        #expect(try Deflate.decompress(packed, expectedSize: whole.count) == whole)
    }
}

@Suite struct LargeODSWriteTests {
    /// A body large enough to spill, with multi-byte text in every row, comes back as valid UTF-8 and the same cells.
    @Test func aSpilledODSBodyIsIntact() throws {
        var wb = Workbook()
        for i in 0..<100_000 {
            wb.sheets[0].append([.text("R\(i)"), .integer(i), .integer(i * 7), .integer(i % 97), .integer(i &* 13 % 1000),
                                 .number(Decimal(i) + Decimal(string: "0.5")!), .number(Decimal(i * 3) + Decimal(string: "0.25")!),
                                 .number(Decimal(i % 31) + Decimal(string: "0.125")!), .text(i % 2 == 0 ? "分類A" : "分類B"), .integer(i * 2)])
        }
        let data = try wb.data(as: .ods)
        let content = try ZipArchive(data: data).read("content.xml")
        #expect(TextEncodingSniffer.firstInvalidUTF8Offset(in: content) == nil, "first bad byte: \(String(describing: TextEncodingSniffer.firstInvalidUTF8Offset(in: content)))")
        let back = try Workbook(data: data)
        #expect(back.sheets[0]["I100000"] == .text("分類B"))
        #expect(back.sheets[0].table.cells.count == wb.sheets[0].table.cells.count)
    }
}
