import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Spec chapter 4 (detection, facade) and chapter 14.2 / 14.8 (read, write, convert, warnings).
@Suite struct FacadeTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static let tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-facade-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    @Test func detectsFormatsFromContent() throws {
        #expect(SheetFormat.detect(from: try Data(contentsOf: Self.fixtures.appendingPathComponent("styled.xlsx"))) == .xlsx)
        #expect(SheetFormat.detect(from: try Data(contentsOf: Self.fixtures.appendingPathComponent("preservation/with-vba.xlsm"))) == .xlsm)
        #expect(SheetFormat.detect(from: Data("a,b\n1,2\n".utf8)) == .csv)
        #expect(SheetFormat.detect(from: Data([0xEF, 0xBB, 0xBF] + Array("名前,値\n".utf8))) == .csv)
        #expect(SheetFormat.detect(from: Data()) == .csv)
        #expect(SheetFormat.detect(from: Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00])) == nil)
        // ODS: a ZIP whose first, stored entry is the mimetype
        var ods = ZipWriter()
        ods.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        ods.add("content.xml", Data("<x/>".utf8))
        #expect(SheetFormat.detect(from: ods.finish()) == .ods)
        var numbers = ZipWriter()
        numbers.add("Index/Document.iwa", Data([1, 2, 3]))
        #expect(SheetFormat.detect(from: numbers.finish()) == .numbers)
        // an unknown ZIP is not a spreadsheet
        var other = ZipWriter()
        other.add("README", Data("hi".utf8))
        #expect(SheetFormat.detect(from: other.finish()) == nil)
        #expect(SheetFormat(fileExtension: "tsv") == .csv)
        #expect(SheetFormat(fileExtension: "XLSM") == .xlsm)
    }

    @Test func brokenContainersFailLoudly() throws {
        var ods = ZipWriter()
        ods.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)   // no content.xml
        #expect(throws: SheetError.self) { try Workbook(data: ods.finish()) }
        #expect(throws: SheetError.unrecognizedFormat) { try Workbook(data: Data([0x00, 0x01, 0xFF, 0xFE])) }
        var numbers = ZipWriter()
        numbers.add("Index/Document.iwa", Data([0, 1, 0, 0, 0]))
        #expect(throws: SheetError.self) { try Workbook(data: numbers.finish()) }
    }

    @Test func everyFormatRoundTripsThroughTheFacade() throws {
        var wb = Workbook()
        wb.sheets[0].name = "集計"
        wb.sheets[0]["A1"] = "名前"; wb.sheets[0]["B1"] = 42; wb.sheets[0]["C1"] = CellValue(CivilDate(year: 2026, month: 9, day: 1)!)
        for format in SheetFormat.allCases {
            let result = try wb.write(as: format)
            #expect(SheetFormat.detect(from: result.data) == format, "\(format)")
            let back = try Workbook(data: result.data)
            #expect(back.sheets[0]["A1"] == .text("名前"), "\(format)")
            if format == .csv {
                #expect(back.sheets[0]["B1"] == .text("42"), "csv keeps text")   // no type inference by default
            } else {
                #expect(back.sheets[0]["B1"]?.intValue == 42, "\(format)")
                #expect(back.sheets[0]["C1"]?.dateValue?.date.description == "2026-09-01", "\(format)")
            }
            #expect(back.sourceInfo?.format == format, "\(format)")
        }
    }

    @Test func readWriteConvertThroughTheFacade() throws {
        var wb = Workbook()
        wb.sheets[0].name = "集計"
        wb.sheets[0].append(["部門", "金額"])
        wb.sheets[0].append(["営業", 1_250_000])
        wb.sheets[0]["C2"] = Formula("=B2*2")
        wb.addSheet(named: "明細")
        let xlsx = Self.tmp.appendingPathComponent("book.xlsx")
        let written = try wb.write(to: xlsx)    // format from the extension
        #expect(written.warnings.isEmpty)
        #expect(SheetFormat.detect(from: try Data(contentsOf: xlsx)) == .xlsx)

        let back = try Workbook(contentsOf: xlsx)
        #expect(back.sheetNames == ["集計", "明細"])
        #expect(back.sheets["集計"]?["B2"] == .integer(1_250_000))
        #expect(back.sheets["集計"]?["C2"]?.formula?.text == "=B2*2")
        #expect(back.sourceInfo?.format == .xlsx)
        #expect(back.sourceInfo?.application == "SwiftSheets")

        // xlsx → csv is a conversion: the second sheet and the formula structure are reported, not silently lost
        let csv = Self.tmp.appendingPathComponent("book.csv")
        let converted = try Workbook.convert(xlsx, to: .csv, output: csv)
        #expect(converted.warnings.contains { $0.kind == .dropped && $0.message.contains("sheet") })
        let text = String(decoding: try Data(contentsOf: csv), as: UTF8.self)
        #expect(text == "部門,金額\r\n営業,1250000,2500000\r\n" || text == "部門,金額,\r\n営業,1250000,=B2*2\r\n", "\(text)")

        // csv → xlsx
        let csvIn = Self.tmp.appendingPathComponent("in.csv")
        try Data("id,name\r\n01234,山田\r\n".utf8).write(to: csvIn)
        let fromCSV = try Workbook(contentsOf: csvIn)
        #expect(fromCSV.sheets[0]["A2"] == .text("01234"))   // no type inference by default
        #expect(fromCSV.sourceInfo?.format == .csv)
        let out = try fromCSV.write(to: Self.tmp.appendingPathComponent("from-csv.xlsx"))
        #expect(out.warnings.isEmpty)
        #expect(try Workbook(contentsOf: Self.tmp.appendingPathComponent("from-csv.xlsx")).sheets[0]["B2"] == .text("山田"))

        // writing without an extension falls back to the source format
        let plain = Self.tmp.appendingPathComponent("plain")
        try fromCSV.write(to: plain)
        #expect(SheetFormat.detect(from: try Data(contentsOf: plain)) == .csv)
        #expect(try wb.data(as: .xlsx).count > 0)
    }

    @Test func tsvByExtensionHint() throws {
        let url = Self.tmp.appendingPathComponent("tabs.tsv")
        try Data("a\tb,c\n1\t2,3\n".utf8).write(to: url)
        let wb = try Workbook(contentsOf: url)
        #expect(wb.sheets[0]["B1"] == .text("b,c"))
    }
}
