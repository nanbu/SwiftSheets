import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Spec chapter 12's first test: open a workbook full of things SwiftSheets does not interpret, change one cell, save,
/// read again — every other cell is intact and every opaque part survived byte for byte (fidelity level F3).
@Suite struct PreservationTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/preservation")
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

    @Test func editOneCellKeepsEverythingElse() throws {
        let original = try Self.fixture("charts-and-friends.xlsx")
        var wb = try XLSXCodec.read(original)
        #expect(wb.sheetNames == ["Data", "Notes"])
        #expect(wb.sheets[0]["A1"] == .text("Item"))
        #expect(wb.sheets[0]["E1"]?.formula?.text == "=SUM(B2:B4)")
        #expect(wb.definedNames["Prices"] == "Data!$C$2:$C$4")
        #expect(wb.preserved.summary.contains("charts: 1"))
        #expect(wb.preserved.summary.contains("comments: 2"))
        #expect(wb.preserved.summary.contains("tables: 1"))
        #expect(wb.preserved.opaqueParts["xl/theme/theme1.xml"] != nil)
        #expect(Set(wb.sheets[0].preserved.fragments.map(\.element)).isSuperset(of: ["conditionalFormatting", "dataValidations", "drawing", "legacyDrawing", "tableParts"]))
        #expect(wb.preserved.styleFragments.contains { $0.element == "dxfs" })

        wb.sheets[0]["B2"] = 30   // the one edit
        let result = try XLSXCodec.write(wb)
        #expect(result.warnings.isEmpty)

        let again = try XLSXCodec.read(result.data)
        #expect(again.sheets[0]["B2"] == .integer(30))
        for (ref, cell) in wb.sheets[0].cells where ref.a1 != "B2" {
            #expect(again.sheets[0].cells[ref]?.value == cell.value, "\(ref.a1)")
            #expect(again.sheets[0].cells[ref]?.style == cell.style, "\(ref.a1) style")
        }
        #expect(again.sheets[1]["A1"] == .text("second sheet"))
        #expect(again.definedNames == wb.definedNames)
        // opaque parts are the same bytes
        let before = try ZipArchive(data: original), after = try ZipArchive(data: result.data)
        for part in ["xl/charts/chart1.xml", "xl/drawings/drawing1.xml", "xl/drawings/_rels/drawing1.xml.rels", "xl/comments/comment1.xml", "xl/drawings/commentsDrawing1.vml", "xl/tables/table1.xml", "xl/theme/theme1.xml", "xl/comments/comment2.xml"] {
            #expect(try before.read(part) == after.read(part), "\(part)")
        }
        // the sheet still points at its drawing, comments and table with the original ids, and the rels still resolve
        let sheetXML = String(decoding: try after.read("xl/worksheets/sheet1.xml"), as: UTF8.self)
        let rels = String(decoding: try after.read("xl/worksheets/_rels/sheet1.xml.rels"), as: UTF8.self)
        for element in ["<drawing ", "<legacyDrawing ", "<tableParts", "<conditionalFormatting", "<dataValidations"] { #expect(sheetXML.contains(element), "\(element)") }
        let ids = sheetXML.components(separatedBy: "r:id=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        #expect(!ids.isEmpty)
        for id in ids { #expect(rels.contains("Id=\"\(id)\""), "dangling \(id)") }
        // element order is the schema's: sheetData before mergeCells/conditionalFormatting before drawing before tableParts
        let order = ["<sheetData>", "<conditionalFormatting", "<dataValidations", "<pageMargins", "<drawing ", "<legacyDrawing ", "<tableParts"]
        let positions = order.map { sheetXML.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
        // content types declare every part that is in the package, and nothing that is not
        let ct = String(decoding: try after.read("[Content_Types].xml"), as: UTF8.self)
        for name in after.entries.keys where name.hasSuffix(".xml") && name != "[Content_Types].xml" && !name.contains("_rels") {
            #expect(ct.contains("PartName=\"/\(name)\""), "undeclared \(name)")
        }
        #expect(!ct.contains("calcChain"))
        #expect(ct.contains("Extension=\"vml\""))
    }

    @Test func styleTablesKeepTheirIndices() throws {
        let wb = try XLSXCodec.read(try Self.fixture("charts-and-friends.xlsx"))
        let out = try XLSXCodec.write(wb).data
        let styles = String(decoding: try ZipArchive(data: out).read("xl/styles.xml"), as: UTF8.self)
        #expect(styles.contains("<dxfs"))
        #expect(styles.contains("<tableStyles"))
        #expect(styles.contains("<cellStyleXfs"))
        let sections = ["<numFmts", "<fonts", "<fills", "<borders", "<cellStyleXfs", "<cellXfs", "<cellStyles", "<dxfs", "<tableStyles"].compactMap { styles.range(of: $0)?.lowerBound }
        #expect(sections == sections.sorted())
        // the bold font openpyxl wrote is still font #1 (its index is referenced by the preserved cellStyleXfs)
        let fonts = styles[styles.range(of: "<fonts")!.upperBound...]
        #expect(fonts.range(of: "<b")!.lowerBound < fonts.range(of: "</fonts>")!.lowerBound)
    }

    @Test func addedHyperlinkNumbersAfterPreservedRelationships() throws {
        var wb = try XLSXCodec.read(try Self.fixture("charts-and-friends.xlsx"))
        wb.sheets[0][cell: "A6"].hyperlink = Hyperlink(target: "https://example.com")
        let out = try ZipArchive(data: try XLSXCodec.write(wb).data)
        let rels = String(decoding: try out.read("xl/worksheets/_rels/sheet1.xml.rels"), as: UTF8.self)
        let ids = rels.components(separatedBy: "Id=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        #expect(Set(ids).count == ids.count, "relationship ids must be unique: \(ids)")
        #expect(rels.contains("example.com"))
    }

    @Test func xlsmKeepsVBAAndXlsxDropsItWithAWarning() throws {
        let data = try Self.fixture("with-vba.xlsm")
        #expect(SheetFormat.detect(from: data) == .xlsm)
        let wb = try Workbook(data: data)
        #expect(wb.sourceInfo?.format == .xlsm)
        #expect(wb.preserved.summary.hasPrefix("VBA project: yes"))

        let kept = try wb.write(as: .xlsm)
        #expect(kept.warnings.isEmpty)
        let keptZip = try ZipArchive(data: kept.data)
        #expect(try keptZip.read("xl/vbaProject.bin") == ZipArchive(data: data).read("xl/vbaProject.bin"))
        #expect(String(decoding: try keptZip.read("[Content_Types].xml"), as: UTF8.self).contains("macroEnabled"))
        #expect(String(decoding: try keptZip.read("xl/_rels/workbook.xml.rels"), as: UTF8.self).contains("vbaProject"))
        #expect(SheetFormat.detect(from: kept.data) == .xlsm)

        let dropped = try wb.write(as: .xlsx)
        #expect(dropped.warnings.contains { $0.kind == .dropped && $0.message.contains("VBA") })
        #expect(dropped.suggestion?.format == .xlsm)
        let droppedZip = try ZipArchive(data: dropped.data)
        #expect(!droppedZip.contains("xl/vbaProject.bin"))
        #expect(!String(decoding: try droppedZip.read("xl/_rels/workbook.xml.rels"), as: UTF8.self).contains("vbaProject"))
        #expect(!String(decoding: try droppedZip.read("[Content_Types].xml"), as: UTF8.self).contains("macroEnabled"))
        #expect(SheetFormat.detect(from: dropped.data) == .xlsx)
    }

    @Test func xlsxToXlsmIsJustTheContentType() throws {
        let wb = Workbook()
        let out = try wb.write(as: .xlsm)
        #expect(out.warnings.isEmpty)
        #expect(SheetFormat.detect(from: out.data) == .xlsm)
        #expect(try Workbook(data: out.data).sheetNames == ["Sheet1"])
    }

    @Test func removingASheetDoesNotLeaveDanglingReferences() throws {
        var wb = try XLSXCodec.read(try Self.fixture("charts-and-friends.xlsx"))
        wb.removeSheet(named: "Notes")
        let out = try ZipArchive(data: try XLSXCodec.write(wb).data)
        let workbookRels = String(decoding: try out.read("xl/_rels/workbook.xml.rels"), as: UTF8.self)
        let workbook = String(decoding: try out.read("xl/workbook.xml"), as: UTF8.self)
        #expect(!out.contains("xl/worksheets/sheet2.xml"))
        #expect(!workbookRels.contains("sheet2.xml"))
        #expect(!workbook.contains("Notes"))
        let ids = workbook.components(separatedBy: "r:id=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        for id in ids { #expect(workbookRels.contains("Id=\"\(id)\""), "dangling \(id)") }
        #expect(try Workbook(data: try XLSXCodec.write(wb).data).sheetNames == ["Data"])
    }

    @Test func readWithoutPreservationIsLean() throws {
        let wb = try XLSXCodec.read(try Self.fixture("charts-and-friends.xlsx"), options: ReadOptions(preserveUnknownParts: false))
        #expect(wb.preserved.opaqueParts.isEmpty)
        #expect(wb.sheets[0]["A1"] == .text("Item"))
    }
}

/// The package details Excel validates when it decides whether to offer "repair". Each of these was a real defect:
/// styles referenced a theme that was not in the package, and the pane element spelled out zero splits.
@Suite struct ExcelCompatibilityTests {
    static func parts(_ data: Data) throws -> (zip: ZipArchive, contentTypes: String, workbookRels: String) {
        let zip = try ZipArchive(data: data)
        return (zip, String(decoding: try zip.read("[Content_Types].xml"), as: UTF8.self),
                String(decoding: try zip.read("xl/_rels/workbook.xml.rels"), as: UTF8.self))
    }

    @Test func aGeneratedWorkbookShipsTheThemeItsStylesReference() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "テーマ"
        let data = try XLSXCodec.write(wb).data
        let (zip, contentTypes, rels) = try Self.parts(data)
        let styles = String(decoding: try zip.read("xl/styles.xml"), as: UTF8.self)
        #expect(styles.contains("<color theme=\"1\"/>"), "the default font uses a theme colour, as Excel's own files do")
        #expect(zip.contains("xl/theme/theme1.xml"), "so the theme part must be there")
        #expect(contentTypes.contains("PartName=\"/xl/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\""))
        #expect(rels.contains("/theme\" Target=\"theme/theme1.xml\""))
        let theme = String(decoding: try zip.read("xl/theme/theme1.xml"), as: UTF8.self)
        for element in ["<a:clrScheme", "<a:dk1>", "<a:lt1>", "<a:accent6>", "<a:hlink>", "<a:folHlink>", "<a:fontScheme", "<a:majorFont>", "<a:minorFont>", "<a:fmtScheme", "<a:fillStyleLst>", "<a:lnStyleLst>", "<a:effectStyleLst>", "<a:bgFillStyleLst>"] {
            #expect(theme.contains(element), "theme is missing \(element)")
        }
        // the format scheme needs three entries in each list
        #expect(theme.components(separatedBy: "<a:ln ").count == 4)
        #expect(theme.components(separatedBy: "<a:effectStyle>").count == 4)
    }

    @Test func aPreservedThemeIsNotDuplicated() throws {
        let source = try Data(contentsOf: PreservationTests.fixtures.appendingPathComponent("charts-and-friends.xlsx"))
        let wb = try XLSXCodec.read(source)
        #expect(wb.preserved.opaqueParts["xl/theme/theme1.xml"] != nil)
        let out = try XLSXCodec.write(wb).data
        let (zip, contentTypes, rels) = try Self.parts(out)
        #expect(try zip.read("xl/theme/theme1.xml") == ZipArchive(data: source).read("xl/theme/theme1.xml"), "the source theme travels unchanged")
        #expect(contentTypes.components(separatedBy: "theme+xml").count == 2, "declared exactly once")
        #expect(rels.components(separatedBy: "/theme\"").count == 2, "related exactly once")
    }

    @Test func frozenPanesAreSpelledTheWayExcelWritesThem() throws {
        var wb = Workbook()
        wb.sheets[0].freezePanes = CellRef("A4")     // rows only
        wb.addSheet(named: "Cols"); wb.sheets[1].freezePanes = CellRef("D1")   // columns only
        wb.addSheet(named: "Both"); wb.sheets[2].freezePanes = CellRef("C3")
        let zip = try ZipArchive(data: try XLSXCodec.write(wb).data)
        let one = String(decoding: try zip.read("xl/worksheets/sheet1.xml"), as: UTF8.self)
        let two = String(decoding: try zip.read("xl/worksheets/sheet2.xml"), as: UTF8.self)
        let three = String(decoding: try zip.read("xl/worksheets/sheet3.xml"), as: UTF8.self)
        #expect(one.contains("<pane ySplit=\"3\" topLeftCell=\"A4\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
        #expect(!one.contains("xSplit"), "a zero split is omitted")
        #expect(two.contains("<pane xSplit=\"3\" topLeftCell=\"D1\" activePane=\"topRight\" state=\"frozen\"/>"))
        #expect(three.contains("<pane xSplit=\"2\" ySplit=\"2\" topLeftCell=\"C3\" activePane=\"bottomRight\" state=\"frozen\"/>"))
        #expect(three.contains("<selection pane=\"topRight\"/><selection pane=\"bottomLeft\"/><selection pane=\"bottomRight\""))
    }

    @Test func fontChildrenFollowTheSchemaOrder() throws {
        var wb = Workbook()
        wb.sheets[0][cell: "A1"].font = Font(name: "游ゴシック", size: 12, bold: true, italic: true, underline: .single, color: .rgb("FFC00000"))
        wb.sheets[0][cell: "A1"].font.charset = 128
        wb.sheets[0][cell: "A1"].font.family = 3
        let styles = String(decoding: try ZipArchive(data: try XLSXCodec.write(wb).data).read("xl/styles.xml"), as: UTF8.self)
        let font = styles.components(separatedBy: "<font>").first { $0.contains("游ゴシック") } ?? ""
        let order = ["<b ", "<i ", "<u ", "<sz ", "<color ", "<name ", "<family ", "<charset "]
        let positions = order.compactMap { font.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count, "every element present: \(font)")
        #expect(positions == positions.sorted(), "CT_Font order: \(font)")
    }
}
