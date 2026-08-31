import Foundation
#if canImport(FoundationXML)
import FoundationXML   // where Foundation is split, the XML parser lives in its own module
#endif
import Testing
@testable import SheetCore
@testable import SheetXLSX

@Suite struct WorkbookParityTests {
    // openpyxl: workbook/tests/test_workbook.py::test_named_styles
    @Test func namedStyles() {
        #expect(StyleRegistry().xml().contains("<cellStyles count=\"1\"><cellStyle name=\"Normal\""))   // only "Normal" exists
    }

    // openpyxl: workbook/tests/test_workbook.py::test_duplicate_defined_name
    @Test func duplicateDefinedName() {
        var wb = Workbook()
        wb.definedNames["dfn1"] = "Sheet1!$A$1"
        #expect(wb.definedNames.keys.contains { $0.lowercased() == "dfn1" } && wb.definedNames.keys.contains { $0.lowercased() == "DFN1".lowercased() })
    }

    // openpyxl: workbook/tests/test_workbook.py::test_get_active_sheet
    @Test func getActiveSheet() {
        // PORT-NOTE: sheets are values, so identity (===) becomes equality plus the active index.
        let wb = Workbook()
        #expect(wb.activeIndex == 0 && wb.activeSheet == wb.sheets[0])
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_active_by_sheet
    @Test func setActiveBySheet() {
        // PORT-NOTE: there is no "make this sheet object active" — the nearest equivalent is activating the index the
        // name resolves to. A fresh workbook already holds "Sheet1", so `addSheet(named: "Sheet1")` becomes "Sheet11";
        // all three listed names still exist in the workbook, as in the openpyxl test.
        var wb = Workbook()
        let names = ["Sheet", "Sheet1", "Sheet2"]
        for n in names { wb.addSheet(named: n) }
        for n in names { wb.activeIndex = wb.sheets.index(of: n)!; #expect(wb.activeSheet == wb.sheets[n]) }
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_active_by_index
    @Test func setActiveByIndex() {
        var wb = Workbook()
        for n in ["Sheet", "Sheet1", "Sheet2"] { wb.addSheet(named: n) }
        for idx in 0..<3 { wb.activeIndex = idx; #expect(wb.activeSheet == wb.sheets[idx]) }
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_invalid_child_as_active
    @Test func setInvalidChildAsActive() {
        // PORT-NOTE: sheets carry no parent workbook, so "a sheet of another workbook" is one whose name is not in
        // this workbook: resolving it yields no index and the active index is untouched; an out-of-range index is
        // clamped to the last sheet (openpyxl raises).
        var wb1 = Workbook(), wb2 = Workbook()
        wb1.addSheet(named: "Other"); wb1.activeIndex = 1
        wb2.sheets[0].name = "Foreign"
        if let i = wb1.sheets.index(of: wb2.sheets[0].name) { wb1.activeIndex = i }
        #expect(wb1.activeIndex == 1)
        wb1.activeIndex = wb1.sheets.count + 3
        #expect(wb1.activeIndex == 1)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_hidden_sheet_as_active
    @Test func setHiddenSheetAsActive() {
        var wb = Workbook()
        let i = wb.addSheet(); wb.sheets[i].state = .hidden
        wb.activeIndex = i
        #expect(wb.activeIndex != i)   // only visible sheets can be made active (openpyxl raises)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_create_sheet
    @Test func createSheet() {
        var wb = Workbook()
        let i = wb.addSheet()
        #expect(i == wb.sheets.count - 1 && wb.sheets[i] == wb.sheets.last)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_create_sheet_with_name
    @Test func createSheetWithName() {
        var wb = Workbook()
        let i = wb.addSheet(named: "LikeThisName")
        #expect(i == wb.sheets.count - 1 && wb.sheets[i].name == "LikeThisName")
    }

    // openpyxl: workbook/tests/test_workbook.py::test_add_correct_sheet
    @Test func addCorrectSheet() {
        var wb = Workbook()
        wb.addSheet(); let i = wb.addSheet()
        #expect(i == 2)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_remove_sheet
    @Test func removeSheet() {
        var wb = Workbook()
        let i = wb.addSheet(at: 0)
        let name = wb.sheets[i].name
        wb.removeSheet(at: i)
        #expect(!wb.sheets.contains(name))
    }

    // openpyxl: workbook/tests/test_workbook.py::test_move_sheet
    @Test func moveSheet() {
        // PORT-NOTE: the default sheet is "Sheet1", so the nine added sheets are named "Sheet", "Sheet2" … "Sheet9"
        // (`Sheet.uniqueName`); the moved sheet is still "Sheet9", from index 9 to index 4.
        var wb = Workbook()
        for _ in 0..<9 { wb.addSheet() }
        #expect(wb.sheetNames == ["Sheet1", "Sheet", "Sheet2", "Sheet3", "Sheet4", "Sheet5", "Sheet6", "Sheet7", "Sheet8", "Sheet9"])
        wb.moveSheet(named: "Sheet9", to: wb.sheets.index(of: "Sheet9")! - 5)
        #expect(wb.sheetNames == ["Sheet1", "Sheet", "Sheet2", "Sheet3", "Sheet9", "Sheet4", "Sheet5", "Sheet6", "Sheet7", "Sheet8"])
        var wb2 = Workbook()
        for _ in 0..<9 { wb2.addSheet() }
        wb2.moveSheet(named: "Sheet9", to: wb2.sheets.index(of: "Sheet9")! - 5)
        #expect(wb2.sheetNames == wb.sheetNames)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_getitem
    @Test func getitem() {
        let wb = Workbook()
        #expect(wb.sheets["Sheet1"] != nil && wb.sheets["NotThere"] == nil)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_del_worksheet
    @Test func delWorksheet() {
        var wb = Workbook()
        wb.removeSheet(named: "Sheet1")
        #expect(wb.sheets.isEmpty)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_contains
    @Test func contains() {
        let wb = Workbook()
        #expect(wb.sheets.contains("Sheet1") && !wb.sheets.contains("NotThere"))
    }

    // openpyxl: workbook/tests/test_workbook.py::test_iter
    @Test func iter() {
        let wb = Workbook()
        var last: Sheet?
        for ws in wb.sheets { last = ws }
        #expect(last?.name == "Sheet1")
    }

    // openpyxl: workbook/tests/test_workbook.py::test_index
    @Test func index() {
        var wb = Workbook()
        let i = wb.addSheet()
        #expect(wb.sheets.index(of: wb.sheets[i].name) == 1)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_get_sheet_names
    @Test func getSheetNames() {
        // PORT-NOTE: default sheet "Sheet1"; the added sheets become "Sheet", "Sheet2" … "Sheet5" (`Sheet.uniqueName`).
        var wb = Workbook()
        for _ in 0..<5 { wb.addSheet() }
        #expect(wb.sheetNames == ["Sheet1", "Sheet", "Sheet2", "Sheet3", "Sheet4", "Sheet5"])
    }

    // openpyxl: workbook/tests/test_workbook.py::test_worksheet_copy
    @Test func worksheetCopy() {
        var wb = Workbook()
        let i = wb.duplicateSheet(named: wb.activeSheet.name)
        #expect(wb.sheets.count == 2 && i == 1)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_worksheet_copy_name
    @Test(arguments: [("TestSheet", "TestSheet Copy"), ("D\u{fc}sseldorf", "D\u{fc}sseldorf Copy")])
    func worksheetCopyName(_ title: String, _ copy: String) {
        var wb = Workbook()
        wb.sheets[wb.activeIndex].name = title
        let i = wb.duplicateSheet(named: wb.activeSheet.name)!
        #expect(wb.sheets[i].name == copy)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_default_epoch
    @Test func defaultEpoch() {
        #expect(Workbook().epoch == .windows1900)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_assign_epoch
    @Test func assignEpoch() {
        var wb = Workbook(); wb.epoch = .mac1904
        #expect(wb.epoch == .mac1904)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_invalid_epoch
    @Test func invalidEpoch() {
        // DateEpoch is a closed enum: 1900 and 1904 are the only values, so an invalid epoch cannot be expressed.
        #expect([DateEpoch.windows1900, .mac1904].count == 2)
    }
}

@Suite struct WorkbookChildParityTests {
    // openpyxl: workbook/tests/test_child.py::test_invalid_chars
    @Test(arguments: ["Title:", "title?", "title/", "title[", "title]", "title\\\\", "title*"]) func invalidChars(_ value: String) {
        #expect(Sheet.validateName(value) != nil)
    }

    static let duplicateCases: [([String], String, String)] = [
        ([], "Sheet", "Sheet"), (["Sheet2"], "Sheet2", "Sheet21"), (["R\u{f3}g"], "R\u{f3}g", "R\u{f3}g1"), (["Sheet", "Sheet1"], "Sheet", "Sheet2"),
        (["Regex Test ("], "Regex Test (", "Regex Test (1"), (["Foo", "Baz", "Sheet2", "Sheet3", "Bar", "Sheet4", "Sheet6"], "Sheet", "Sheet"), (["Foo"], "FOO", "FOO1"),
    ]
    // openpyxl: workbook/tests/test_child.py::test_duplicate_title
    @Test(arguments: duplicateCases)
    func duplicateTitle(_ names: [String], _ value: String, _ result: String) {
        #expect(Sheet.uniqueName(value, among: names) == result)
    }

    // openpyxl: workbook/tests/test_child.py::test_ctor
    @Test func ctor() {
        // PORT-NOTE: no parent back-reference on a value-type Sheet — membership is `wb.sheets.contains(name)`. The
        // default sheet is "Sheet1", so the added sheet keeps its default name "Sheet" (the old port expected "Sheet1").
        var wb = Workbook()
        let i = wb.addSheet()
        #expect(wb.sheets.contains(wb.sheets[i].name) && wb.sheets[i].name == "Sheet")
    }

    // openpyxl: workbook/tests/test_child.py::test_invalid_title
    @Test func invalidTitle() {
        var wb = Workbook()
        wb.sheets[wb.activeIndex].name = "title?"
        #expect(wb.activeSheet.name == "Sheet1")   // rejected: the previous title stays (openpyxl raises)
    }

    // openpyxl: workbook/tests/test_child.py::test_reassign_title
    @Test func reassignTitle() {
        var wb = Workbook()
        wb.sheets[wb.activeIndex].name = "Sheet1"
        #expect(wb.activeSheet.name == "Sheet1")
    }

    // openpyxl: workbook/tests/test_child.py::test_title_too_long
    @Test func titleTooLong() {
        var wb = Workbook()
        wb.sheets[wb.activeIndex].name = String(repeating: "X", count: 50)
        #expect(wb.activeSheet.name.count == 50)   // accepted with a warning in openpyxl; accepted silently here
    }

    // openpyxl: workbook/tests/test_child.py::test_empty_title
    @Test func emptyTitle() {
        var wb = Workbook()
        wb.sheets[wb.activeIndex].name = ""
        #expect(wb.activeSheet.name == "Sheet1" && Sheet.validateName("") != nil)
    }
}

@Suite struct WorkbookDefinedNameParityTests {
    // openpyxl: workbook/tests/test_defined_name.py::test_write
    @Test func write() throws {
        var wb = Workbook(); wb.definedNames["test"] = "Sheet1!$A$1"
        let data = try XLSXCodec.write(wb).data
        let xml = String(decoding: try ZipArchive(data: data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<definedNames><definedName name=\"test\">Sheet1!$A$1</definedName></definedNames>"))
    }

    /// The fixture is a bare `<definedNames>` fragment; the parser now keeps unknown depth-2 children of the root
    /// verbatim (preservation), so `<definedName>` is only interpreted under a `<workbook>` root as in a real file.
    static func workbookDocument(_ fragment: Data) -> Data {
        let xml = String(decoding: fragment, as: UTF8.self)
        return xml.contains("<workbook") ? fragment : Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(xml)</workbook>".utf8)
    }

    // openpyxl: workbook/tests/test_defined_name.py::test_read
    @Test func read() throws {
        // PORT-NOTE: the fragment fixture is wrapped in a `<workbook>` root (see `workbookDocument`); the expectations are unchanged.
        let p = WorkbookXMLParser()
        try p.run(Self.workbookDocument(try openpyxlFixture("workbook/defined_names.xml")), part: "workbook.xml")
        #expect(p.definedNames.count + p.localNames.values.reduce(0) { $0 + $1.count } == 6)
        #expect(p.definedNames["MyRef"] == "Sheet1!$A$1" && p.definedNames["MyValue"] == "9.99")
    }

    // openpyxl: workbook/tests/test_defined_name.py::test_by_sheet
    @Test func bySheet() throws {
        // PORT-NOTE: same `<workbook>` wrapping as `read()`; the expectations are unchanged.
        let p = WorkbookXMLParser()
        try p.run(Self.workbookDocument(try openpyxlFixture("workbook/defined_names.xml")), part: "workbook.xml")
        #expect(p.localNames[0] == ["MySheetRef": "Sheet1!$A$3", "MySheetValue": "3.33"] && p.localNames[1] == ["MySheetRef": "Sheet2!$A$1", "MySheetValue": "14.4"])
    }
}

@Suite struct WorkbookPropertiesParityTests {
    // openpyxl: workbook/tests/test_properties.py::TestWorkbookProperties::test_ctor
    @Test func workbookPropertiesCtor() throws {
        var wb = Workbook(); wb.epoch = .mac1904
        let xml = String(decoding: try ZipArchive(data: try XLSXCodec.write(wb).data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<workbookPr date1904=\"1\"/>"))
    }

    // openpyxl: workbook/tests/test_properties.py::TestWorkbookProperties::test_from_xml
    @Test func workbookPropertiesFromXML() throws {
        let p = WorkbookXMLParser()
        try p.run(Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><workbookPr date1904=\"1\" codeName=\"ThisWorkbook\"/></workbook>".utf8), part: "wb")
        #expect(p.date1904)
    }

    // openpyxl: workbook/tests/test_properties.py::TestCalcProperties::test_ctor
    @Test func calcPropertiesCtor() throws {
        let xml = String(decoding: try ZipArchive(data: try XLSXCodec.write(Workbook()).data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/>"))
    }
}

@Suite struct WorkbookViewsParityTests {
    // openpyxl: workbook/tests/test_views.py::TestBookView::test_ctor
    @Test func bookViewCtor() throws {
        var wb = Workbook(); wb.addSheet(); wb.activeIndex = 1
        let xml = String(decoding: try ZipArchive(data: try XLSXCodec.write(wb).data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<bookViews><workbookView activeTab=\"1\"/></bookViews>"))
    }

    // openpyxl: workbook/tests/test_views.py::TestBookView::test_from_xml
    @Test func bookViewFromXML() throws {
        let p = WorkbookXMLParser()
        try p.run(Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><bookViews><workbookView activeTab=\"1\" visibility=\"visible\"/></bookViews></workbook>".utf8), part: "wb")
        #expect(p.activeTab == 1)
    }
}

@Suite struct WorkbookWriterParityTests {
    func workbookXML(_ wb: Workbook) throws -> String { String(decoding: try ZipArchive(data: try XLSXCodec.write(wb).data).read("xl/workbook.xml"), as: UTF8.self) }
    func unicodeWorkbook() -> Workbook { var wb = Workbook(); wb.sheets[0].name = "D\u{fc}sseldorf Sheet"; return wb }

    // openpyxl: workbook/tests/test_writer.py::test_hidden_worksheet
    @Test func hiddenWorksheet() throws {
        // PORT-NOTE: the default sheet is "Sheet1" and the added one "Sheet" (was "Sheet" / "Sheet1").
        var wb = Workbook(); wb.sheets[0].state = .hidden; wb.addSheet(); wb.activeIndex = 1
        let xml = try workbookXML(wb)
        #expect(xml.contains("<workbookView activeTab=\"1\"/>") && xml.contains("<sheet name=\"Sheet1\" sheetId=\"1\" state=\"hidden\" r:id=\"rId1\"/><sheet name=\"Sheet\" sheetId=\"2\" r:id=\"rId2\"/>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_workbook
    @Test func workbook() throws {
        let xml = try workbookXML(Workbook())
        #expect(xml.contains("<workbookPr/><bookViews><workbookView activeTab=\"0\"/></bookViews><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets><calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/></workbook>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_workbook_code_name
    @Test func workbookCodeName() throws {
        var wb = Workbook(); wb.codeName = "MyWB"
        #expect(try workbookXML(wb).contains("<workbookPr codeName=\"MyWB\"/>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_print_area
    @Test func printArea() throws {
        var wb = unicodeWorkbook(); wb.sheets[0].setPrintArea("A1:D4")
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">'D\u{fc}sseldorf Sheet'!$A$1:$D$4</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_print_titles
    @Test func printTitles() throws {
        var wb = unicodeWorkbook(); wb.sheets[0].setPrintTitleRows("1:5")
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">'D\u{fc}sseldorf Sheet'!$1:$5</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_autofilter
    @Test func autofilter() throws {
        var wb = unicodeWorkbook(); wb.sheets[0].autoFilter = CellRange("A1:A10")
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">'D\u{fc}sseldorf Sheet'!$A$1:$A$10</definedName></definedNames>"))
        let back = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook
        #expect(back.activeSheet.autoFilter?.a1 == "A1:A10" && back.activeSheet.definedNames.isEmpty)
    }

    // openpyxl: workbook/tests/test_writer.py::test_defined_name_global
    @Test func definedNameGlobal() throws {
        var wb = unicodeWorkbook(); wb.definedNames["MyConstant"] = "3.14"
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"MyConstant\">3.14</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_defined_name_locall
    @Test func definedNameLocal() throws {
        var wb = unicodeWorkbook()
        wb.sheets[0].definedNames["MyReference"] = "\(CellRef.quoteSheetName(wb.activeSheet.name))!$A$1:$A$10"
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"MyReference\" localSheetId=\"0\">'D\u{fc}sseldorf Sheet'!$A$1:$A$10</definedName></definedNames>"))
        #expect(try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook.activeSheet.definedNames["MyReference"] == "'D\u{fc}sseldorf Sheet'!$A$1:$A$10")
    }
}
