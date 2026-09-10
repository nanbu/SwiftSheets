import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Links on runs of a cell's text (spec Appendix B.81): ODS and Numbers hang a link on a stretch of text, so a
/// cell may carry several; rich text carries them run by run, and Excel keeps the first and says so.
struct RunHyperlinkTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ods/two-links.ods")

    static func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0]["A1"] = .richText([
            TextRun("See "),
            TextRun("the first site", hyperlink: Hyperlink(target: "https://example.com/a")),
            TextRun(" and "),
            TextRun("the second", font: Font(bold: true), hyperlink: Hyperlink(target: "https://example.com/b")),
            TextRun("."),
        ])
        return wb
    }

    static func check(_ value: CellValue?, _ label: String) {
        guard case .richText(let runs)? = value else { Issue.record("\(label): \(String(describing: value))"); return }
        #expect(runs.map(\.text).joined() == "See the first site and the second.", "\(label): \(runs.map(\.text))")
        #expect(runs.compactMap(\.hyperlink?.target) == ["https://example.com/a", "https://example.com/b"], "\(label): \(runs)")
        #expect(runs.first { $0.text == "the second" }?.font?.bold == true, "\(label): \(runs)")
        #expect(runs.first { $0.text == "See " }?.hyperlink == nil, Comment(rawValue: label))
    }

    @Test func odsReadsEveryLinkOntoItsRun() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        Self.check(wb.sheets[0]["A1"], "the ODF form: a link around a span")
        #expect(wb.sheets[0][cell: "A1"].hyperlink?.target == "https://example.com/a", "the cell's own link is still the first")
        #expect(!wb.readWarnings.contains { $0.message.contains("more than one hyperlink") }, "\(wb.readWarnings.map(\.message))")
        #expect(wb.sheets[0]["A2"] == .text("one link") && wb.sheets[0][cell: "A2"].hyperlink?.target == "https://example.com/only", "one link stays plain text with the cell's link")
    }

    @Test func odsWritesEachLinkOnItsRun() throws {
        let result = try Self.workbook().write(as: .ods)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let content = try Package.part("content.xml", of: result.data)
        #expect(content.components(separatedBy: "<text:a ").count == 3 && content.contains("xlink:href=\"https://example.com/b\" xlink:type=\"simple\"><text:span"))
        Self.check(try Workbook.read(result.data, format: .ods).workbook.sheets[0]["A1"], "ods")
    }

    @Test func xlsxKeepsTheFirstLinkAndSaysSo() throws {
        let result = try Self.workbook().write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("1 link(s) on parts of a cell's text dropped") }, "\(result.warnings.map(\.message))")
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back[cell: "A1"].hyperlink?.target == "https://example.com/a")
        if case .richText(let runs)? = back["A1"] { #expect(runs.allSatisfy { $0.hyperlink == nil } && runs.map(\.text).joined() == "See the first site and the second.") } else { Issue.record("\(String(describing: back["A1"]))") }
        var own = Self.workbook()
        own.sheets[0][cell: "A1"].hyperlink = Hyperlink(target: "https://example.com/cell")
        let result2 = try own.write(as: .xlsx)
        #expect(result2.warnings.contains { $0.message.contains("2 link(s) on parts") }, "the cell's own link wins over both: \(result2.warnings.map(\.message))")
    }

    @Test func numbersRoundTripsTheLinksRunByRun() throws {
        let result = try Self.workbook().write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("link") }, "\(result.warnings.map(\.message))")
        let back = try Workbook.read(result.data, format: .numbers).workbook
        Self.check(back.sheets[0]["A1"], "numbers")
        #expect(back.sheets[0][cell: "A1"].hyperlink?.target == "https://example.com/a")
        #expect(!back.readWarnings.contains { $0.message.contains("links; a cell carries one") }, "\(back.readWarnings.map(\.message))")
    }
}
