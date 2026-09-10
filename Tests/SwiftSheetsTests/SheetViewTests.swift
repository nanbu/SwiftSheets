import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The sheet view's remaining words and the calculation mode (spec Appendix B.76): row and column headers, zeros,
/// right-to-left, the scrolled corner and the view kind on `SheetView`; `calcMode` on the calculation settings.
/// XLSX carries all of them; ODS carries what LibreOffice's settings and the table style can say.
@Suite(.serialized) struct SheetViewTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ods/libreoffice-view.ods")
    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsSheetView", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "V"
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].view.showsGridLines = false
        wb.sheets[0].view.showsRowColumnHeaders = false
        wb.sheets[0].view.showsZeros = false
        wb.sheets[0].view.rightToLeft = true
        wb.sheets[0].view.topLeftCell = CellRef("C5")
        wb.sheets[0].view.zoomScale = 150
        wb.sheets.append(Sheet(name: "W"))
        wb.sheets[1].view.kind = .pageBreakPreview
        wb.sheets[1].freezePanes = CellRef("B3")
        wb.sheets[1].view.topLeftCell = CellRef("D10")
        wb.calculationSettings.calcMode = .manual
        return wb
    }

    @Test func xlsxCarriesEveryField() throws {
        let result = try Self.workbook().write(as: .xlsx)
        let sheet1 = try Package.part("xl/worksheets/sheet1.xml", of: result.data)
        #expect(sheet1.contains("showRowColHeaders=\"0\"") && sheet1.contains("showZeros=\"0\"") && sheet1.contains("rightToLeft=\"1\"") && sheet1.contains("topLeftCell=\"C5\""))
        #expect(try Package.part("xl/worksheets/sheet2.xml", of: result.data).contains("view=\"pageBreakPreview\""))
        #expect(try Package.part("xl/workbook.xml", of: result.data).contains("calcMode=\"manual\""))
        let back = try Workbook.read(result.data, format: .xlsx).workbook
        var expected = Self.workbook().sheets[0].view
        expected.tabSelected = true   // the active sheet's tab is selected on write
        #expect(back.sheets[0].view == expected)
        #expect(back.sheets[1].view.kind == .pageBreakPreview && back.sheets[1].view.topLeftCell == CellRef("D10"))
        #expect(back.calculationSettings.calcMode == .manual)
        // the defaults leave no trace, and read back as nil / true
        let plain = try Workbook().write(as: .xlsx)
        #expect(try !Package.part("xl/worksheets/sheet1.xml", of: plain.data).contains("showRowColHeaders"))
        #expect(try !Package.part("xl/workbook.xml", of: plain.data).contains("calcMode"))
        #expect(try Workbook.read(plain.data, format: .xlsx).workbook.calculationSettings.calcMode == nil)
    }

    @Test func odsCarriesWhatLibreOfficeSaves() throws {
        let result = try Self.workbook().write(as: .ods)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("pageBreakPreview view") }, "\(result.warnings.map(\.message))")
        let settings = try Package.part("settings.xml", of: result.data)
        #expect(settings.contains("config:name=\"AutoCalculate\" config:type=\"boolean\">false<"))
        #expect(settings.contains("config:name=\"ZoomValue\" config:type=\"int\">150<"))
        #expect(try Package.part("content.xml", of: result.data).contains("style:writing-mode=\"rl-tb\""))
        let back = try Workbook.read(result.data, format: .ods).workbook
        let v = back.sheets[0].view
        #expect(!v.showsGridLines && !v.showsRowColumnHeaders && !v.showsZeros && v.rightToLeft && v.zoomScale == 150 && v.topLeftCell == CellRef("C5"), "\(v)")
        #expect(back.sheets[1].freezePanes == CellRef("B3") && back.sheets[1].view.topLeftCell == CellRef("D10"), "the scrolled corner past a frozen split: \(String(describing: back.sheets[1].view.topLeftCell))")
        #expect(back.calculationSettings.calcMode == .manual)
        #expect(back.sheets[1].view.kind == .normal, "ODF saves no view kind")
    }

    /// A headless LibreOffice writes the view items at document level only (no per-sheet entry); they still land.
    @Test func readsLibreOfficesDocumentLevelViewSettings() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        let v = wb.sheets[0].view
        #expect(!v.showsGridLines && !v.showsZeros && !v.showsRowColumnHeaders && v.rightToLeft, "\(v)")
        #expect(wb.sheets[1].view.rightToLeft == false)
        #expect(wb.calculationSettings.calcMode == .manual)
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeReadsTheViewSettingsBack() throws {
        let file = Self.tmp.appendingPathComponent("view.ods")
        try Self.workbook().write(to: file, as: .ods)
        let xlsx = try ODSImageTests.convert(file, to: "xlsx")
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: Data(contentsOf: xlsx))
        #expect(sheet.contains("showGridLines=\"false\"") && sheet.contains("showRowColHeaders=\"false\"") && sheet.contains("showZeros=\"false\"") && sheet.contains("rightToLeft=\"true\""), "\(sheet.prefix(600))")
        // LibreOffice 26.2.3 does not write calcMode into XLSX (measured); the setting itself is judged by the ODS reading above
    }
}
