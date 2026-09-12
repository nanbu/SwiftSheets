import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// The phonetic guide (furigana) over a cell's text rides the shared-string table as `<rPh>` runs and a
/// `<phoneticPr>` (spec Appendix B.70): written, read back, kept apart from the same text without readings,
/// and reported by the writers that have no place for it.
struct FuriganaTests {
    static func workbook() -> Workbook {
        var wb = Workbook()
        var s = wb.sheets[0]
        s["A1"] = "漢字"
        s[cell: "A1"].phonetic = PhoneticText("カンジ", over: "漢字")
        s["A2"] = "東京都"
        var runs = PhoneticText(runs: [.init("トウキョウ", over: 0..<2), .init("ト", over: 2..<3)],
                                kind: .hiragana, alignment: .center)
        runs.font = Font(name: "Meiryo", size: 6)
        s[cell: "A2"].phonetic = runs
        s["A3"] = "漢字"                                  // the same text, no readings
        s["A4"] = .richText([TextRun("漢", font: Font(bold: true)), TextRun("字")])
        s[cell: "A4"].phonetic = PhoneticText("カンジ", over: "漢字")
        wb.sheets[0] = s
        return wb
    }

    /// A shared-string table without furigana keeps no phonetic slot at all, rather than an empty one per entry (spec
    /// Appendix B.93). Each empty slot cost about 80 bytes: 16 MB more at the peak of a row-by-row read of ten million
    /// cells holding a hundred thousand strings. With furigana the slots stay aligned with the strings.
    @Test func aTableWithoutFuriganaKeepsNoPhoneticSlots() throws {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let plain = SharedStringsParser()
        try plain.run(Data("<sst xmlns=\"\(ns)\"><si><t>a</t></si><si><t>b</t></si><si><r><t>c</t></r></si></sst>".utf8), part: "sst")
        #expect(plain.strings.count == 3)
        #expect(plain.resolvedPhonetics(fonts: []).isEmpty)

        let mixed = SharedStringsParser()
        try mixed.run(Data("<sst xmlns=\"\(ns)\"><si><t>a</t></si><si><t>漢字</t><rPh sb=\"0\" eb=\"2\"><t>カンジ</t></rPh><phoneticPr fontId=\"0\"/></si><si><t>b</t></si></sst>".utf8), part: "sst")
        let phonetics = mixed.resolvedPhonetics(fonts: [])
        #expect(phonetics.count == 3, "aligned with the strings")
        #expect(phonetics[0] == nil && phonetics[2] == nil)
        #expect(phonetics[1]?.runs.first?.text == "カンジ")
    }

    @Test func theTableCarriesRunsAndProperties() throws {
        let data = try Self.workbook().write(as: .xlsx).data
        let sst = try Package.part("xl/sharedStrings.xml", of: data)
        #expect(sst.contains("<si><t>漢字</t><rPh sb=\"0\" eb=\"2\"><t>カンジ</t></rPh><phoneticPr fontId=\"0\" type=\"fullwidthKatakana\" alignment=\"left\"/></si>"))
        #expect(sst.contains("<rPh sb=\"0\" eb=\"2\"><t>トウキョウ</t></rPh><rPh sb=\"2\" eb=\"3\"><t>ト</t></rPh><phoneticPr fontId=\"1\" type=\"hiragana\" alignment=\"center\"/>"))
        #expect(sst.contains("<si><t>漢字</t></si>"), "the same text without readings is its own entry")
        #expect(sst.contains("uniqueCount=\"4\""))
        let styles = try Package.part("xl/styles.xml", of: data)
        #expect(styles.contains("Meiryo"), "the readings' font is registered in the font table")
    }

    @Test func readsBackWhatItWrote() throws {
        let wb = Self.workbook()
        let back = try Workbook.read(try wb.write(as: .xlsx).data, format: .xlsx).workbook.sheets[0]
        #expect(back[cell: "A1"].phonetic == PhoneticText("カンジ", over: "漢字"))
        #expect(back[cell: "A2"].phonetic == wb.sheets[0][cell: "A2"].phonetic)
        #expect(back[cell: "A3"].phonetic == nil)
        #expect(back[cell: "A4"].phonetic == PhoneticText("カンジ", over: "漢字"))
        #expect(back["A4"] == wb.sheets[0]["A4"], "rich text keeps its runs beside the readings")
        #expect(back["A2"] == .text("東京都"))
    }

    /// Excel writes the readings on an inline string too; the sheet parser reads those the same way.
    @Test func readsAnInlineString() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let data = try wb.write(as: .xlsx).data
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: data)
        let patched = sheet.replacingOccurrences(
            of: "<c r=\"A1\" t=\"s\"><v>0</v></c>",
            with: "<c r=\"A1\" t=\"inlineStr\"><is><t>漢字</t><rPh sb=\"0\" eb=\"2\"><t>カンジ</t></rPh><phoneticPr fontId=\"0\" type=\"noConversion\" alignment=\"distributed\"/></is></c>")
        #expect(patched != sheet)
        let repacked = try Package.repacking(data, replacing: "xl/worksheets/sheet1.xml", with: Data(patched.utf8))
        let cell = try Workbook.read(repacked, format: .xlsx).workbook.sheets[0][cell: "A1"]
        #expect(cell.value == .text("漢字"))
        #expect(cell.phonetic == PhoneticText(runs: [.init("カンジ", over: 0..<2)], kind: .noConversion, alignment: .distributed, font: nil))
    }

    @Test func theOtherWritersSaySo() throws {
        let wb = Self.workbook()
        for format in [SheetFormat.ods, .numbers] {
            let result = try wb.write(as: format)
            let w = result.warnings.filter { $0.message.contains("3 phonetic guide(s) (furigana) dropped") }
            #expect(w.count == 1 && w[0].kind == .dropped, "\(format): \(result.warnings.map(\.message))")
        }
        // and the readings do not make a cell differ from itself
        var a = Cell(value: .text("漢字")); a.phonetic = PhoneticText("カンジ", over: "漢字")
        var b = a; b.phonetic = nil
        #expect(a != b && a == a)
    }
}
