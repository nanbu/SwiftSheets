import Foundation
import Testing
import SwiftSheets

/// Synthetic integration coverage: drawing inspection, array metadata and opaque-part preservation coexist.
@Suite struct ConsumerInteropTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/interop/consumer-contract.xlsx")

    @Test func sourceInformationAndUnrelatedEditsCoexist() throws {
        let source = try Data(contentsOf: Self.fixture)
        var workbook = try Workbook.read(source).workbook
        let sheet = workbook.sheets[0]
        let drawing = try #require(sheet.drawingInfo)
        #expect(drawing.objects.map(\.kind) == [.group, .shape, .shape])
        #expect(drawing.objects[0].children.first?.children.first?.name == "Grouped text")
        #expect(drawing.objects[1].transform?.rotation == 30)
        #expect(drawing.objects[1].transform?.isHorizontallyFlipped == true)
        #expect(drawing.objects[1].textBody?.paragraphs.first?.runs.first?.text == "日本語")
        #expect(drawing.objects[1].textBody?.attributes["lIns"] == "31750")
        #expect(drawing.objects[1].textBody?.insets.left == 31750)
        #expect(drawing.objects[1].textBody?.insets.bottom == 127000)
        #expect(drawing.objects[1].textBody?.verticalAlignment == .center)
        #expect(drawing.objects[1].textBody?.paragraphs.first?.alignment == .center)
        #expect(sheet.table.dynamicArrayOrigins == [CellRef("D1")!])
        #expect(sheet.table.arrayFormulas[CellRef("H1")!] == CellRange("H1:H2"))
        workbook.sheets[0]["K1"] = "unrelated edit"
        let saved = try workbook.write(as: .xlsx)
        let before = try ZipInspection(data: source), after = try ZipInspection(data: saved.data)
        for part in ["xl/drawings/drawing1.xml", "xl/metadata/arrays.xml", "xl/custom/opaque.bin"] {
            #expect(before.entry(named: part) == after.entry(named: part), Comment(rawValue: part))
        }
        let reread = try Workbook.read(saved.data).workbook
        #expect(reread.sheets[0].drawingInfo == drawing)
        #expect(reread.sheets[0].table.dynamicArrayOrigins == sheet.table.dynamicArrayOrigins)
        #expect(reread.sheets[0]["K1"] == .text("unrelated edit"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSHEETS_CONSUMER_INTEROP_DIR"] != nil,
                   "Set SWIFTSHEETS_CONSUMER_INTEROP_DIR through Tests/ConsumerInterop/verify_with_openpyxl.py"))
    func writesVerificationWorkbook() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SWIFTSHEETS_CONSUMER_INTEROP_DIR"])
        var workbook = try Workbook(contentsOf: Self.fixture)
        workbook.sheets[0]["K1"] = "unrelated edit"
        _ = try workbook.write(to: URL(fileURLWithPath: directory).appendingPathComponent("consumer-contract.xlsx"))
        var created = Workbook()
        created.sheets[0]["A1"] = 3
        created.sheets[0]["B2"] = .formula(.parse("SEQUENCE(A1)"), cached: .integer(1))
        created.sheets[0]["B3"] = 2
        created.sheets[0]["B4"] = 3
        created.sheets[0].table.arrayFormulas[CellRef("B2")!] = CellRange("B2:B4")!
        created.sheets[0].table.dynamicArrayOrigins.insert(CellRef("B2")!)
        _ = try created.write(to: URL(fileURLWithPath: directory).appendingPathComponent("new-dynamic.xlsx"))
    }
}
