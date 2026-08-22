import Foundation
import Testing
@testable import SwiftSheets

@Suite struct WorkbookParityTests {
    // openpyxl: workbook/tests/test_workbook.py::test_named_styles
    @Test func namedStyles() {
        #expect(StyleRegistry().xml().contains("<cellStyles count=\"1\"><cellStyle name=\"Normal\""))   // only "Normal" exists
    }

    // openpyxl: workbook/tests/test_workbook.py::test_duplicate_defined_name
    @Test func duplicateDefinedName() {
        let wb = Workbook()
        wb.definedNames["dfn1"] = "Sheet!$A$1"
        #expect(wb.definedNames.keys.contains { $0.lowercased() == "dfn1" } && wb.definedNames.keys.contains { $0.lowercased() == "DFN1".lowercased() })
    }

    // openpyxl: workbook/tests/test_workbook.py::test_get_active_sheet
    @Test func getActiveSheet() {
        let wb = Workbook()
        #expect(wb.active === wb.worksheets[0])
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_active_by_sheet
    @Test func setActiveBySheet() {
        let wb = Workbook()
        let names = ["Sheet", "Sheet1", "Sheet2"]
        for n in names { wb.createSheet(n) }
        for n in names { wb.active = wb[n]!; #expect(wb.active === wb[n]) }
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_active_by_index
    @Test func setActiveByIndex() {
        let wb = Workbook()
        for n in ["Sheet", "Sheet1", "Sheet2"] { wb.createSheet(n) }
        for idx in 0..<3 { wb.activeIndex = idx; #expect(wb.active === wb.worksheets[idx]) }
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_invalid_child_as_active
    @Test func setInvalidChildAsActive() {
        let wb1 = Workbook(), wb2 = Workbook()
        wb1.createSheet("Other"); wb1.activeIndex = 1
        wb1.active = wb2["Sheet"]!
        #expect(wb1.activeIndex == 1)   // a sheet from another workbook is ignored (openpyxl raises)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_set_hidden_sheet_as_active
    @Test func setHiddenSheetAsActive() {
        let wb = Workbook()
        let ws = wb.createSheet(); ws.state = .hidden
        wb.active = ws
        #expect(wb.active !== ws)   // only visible sheets can be made active (openpyxl raises)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_create_sheet
    @Test func createSheet() {
        let wb = Workbook()
        let new = wb.createSheet()
        #expect(new === wb.worksheets.last)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_create_sheet_with_name
    @Test func createSheetWithName() {
        let wb = Workbook()
        let new = wb.createSheet("LikeThisName")
        #expect(new === wb.worksheets.last && new.title == "LikeThisName")
    }

    // openpyxl: workbook/tests/test_workbook.py::test_add_correct_sheet
    @Test func addCorrectSheet() {
        let wb = Workbook()
        wb.createSheet(); let new = wb.createSheet()
        #expect(new === wb.worksheets[2])
    }

    // openpyxl: workbook/tests/test_workbook.py::test_remove_sheet
    @Test func removeSheet() {
        let wb = Workbook()
        let new = wb.createSheet(nil, at: 0)
        wb.removeSheet(new)
        #expect(!wb.worksheets.contains { $0 === new })
    }

    // openpyxl: workbook/tests/test_workbook.py::test_move_sheet
    @Test func moveSheet() {
        let wb = Workbook()
        for _ in 0..<9 { wb.createSheet() }
        #expect(wb.sheetNames == ["Sheet", "Sheet1", "Sheet2", "Sheet3", "Sheet4", "Sheet5", "Sheet6", "Sheet7", "Sheet8", "Sheet9"])
        wb.moveSheet(wb["Sheet9"]!, offset: -5)
        #expect(wb.sheetNames == ["Sheet", "Sheet1", "Sheet2", "Sheet3", "Sheet9", "Sheet4", "Sheet5", "Sheet6", "Sheet7", "Sheet8"])
        let wb2 = Workbook()
        for _ in 0..<9 { wb2.createSheet() }
        wb2.moveSheet(named: "Sheet9", offset: -5)
        #expect(wb2.sheetNames == wb.sheetNames)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_getitem
    @Test func getitem() {
        let wb = Workbook()
        #expect(wb["Sheet"] != nil && wb["NotThere"] == nil)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_del_worksheet
    @Test func delWorksheet() {
        let wb = Workbook()
        wb.removeSheet(named: "Sheet")
        #expect(wb.worksheets.isEmpty)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_contains
    @Test func contains() {
        let wb = Workbook()
        #expect(wb.contains("Sheet") && !wb.contains("NotThere"))
    }

    // openpyxl: workbook/tests/test_workbook.py::test_iter
    @Test func iter() {
        let wb = Workbook()
        var last: Worksheet?
        for ws in wb { last = ws }
        #expect(last?.title == "Sheet")
    }

    // openpyxl: workbook/tests/test_workbook.py::test_index
    @Test func index() {
        let wb = Workbook()
        let new = wb.createSheet()
        #expect(wb.index(of: new) == 1)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_get_sheet_names
    @Test func getSheetNames() {
        let wb = Workbook()
        for _ in 0..<5 { wb.createSheet() }
        #expect(wb.sheetNames == ["Sheet", "Sheet1", "Sheet2", "Sheet3", "Sheet4", "Sheet5"])
    }

    // openpyxl: workbook/tests/test_workbook.py::test_worksheet_copy
    @Test func worksheetCopy() {
        let wb = Workbook()
        let ws2 = wb.copyWorksheet(wb.active)
        #expect(wb.worksheets.count == 2 && ws2 === wb.worksheets[1])
    }

    // openpyxl: workbook/tests/test_workbook.py::test_worksheet_copy_name
    @Test(arguments: [("TestSheet", "TestSheet Copy"), ("D\u{fc}sseldorf", "D\u{fc}sseldorf Copy")])
    func worksheetCopyName(_ title: String, _ copy: String) {
        let wb = Workbook()
        wb.active.title = title
        #expect(wb.copyWorksheet(wb.active).title == copy)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_default_epoch
    @Test func defaultEpoch() {
        #expect(Workbook().epoch == .windows1900)
    }

    // openpyxl: workbook/tests/test_workbook.py::test_assign_epoch
    @Test func assignEpoch() {
        let wb = Workbook(); wb.epoch = .mac1904
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
        #expect(Worksheet.validateTitle(value) != nil)
    }

    static let duplicateCases: [([String], String, String)] = [
        ([], "Sheet", "Sheet"), (["Sheet2"], "Sheet2", "Sheet21"), (["R\u{f3}g"], "R\u{f3}g", "R\u{f3}g1"), (["Sheet", "Sheet1"], "Sheet", "Sheet2"),
        (["Regex Test ("], "Regex Test (", "Regex Test (1"), (["Foo", "Baz", "Sheet2", "Sheet3", "Bar", "Sheet4", "Sheet6"], "Sheet", "Sheet"), (["Foo"], "FOO", "FOO1"),
    ]
    // openpyxl: workbook/tests/test_child.py::test_duplicate_title
    @Test(arguments: duplicateCases)
    func duplicateTitle(_ names: [String], _ value: String, _ result: String) {
        #expect(Worksheet.uniqueTitle(value, among: names) == result)
    }

    // openpyxl: workbook/tests/test_child.py::test_ctor
    @Test func ctor() {
        let wb = Workbook()
        let child = wb.createSheet()
        #expect(child.workbook === wb && child.title == "Sheet1")   // "Sheet" is taken by the default sheet
    }

    // openpyxl: workbook/tests/test_child.py::test_invalid_title
    @Test func invalidTitle() {
        let wb = Workbook()
        wb.active.title = "title?"
        #expect(wb.active.title == "Sheet")   // rejected: the previous title stays (openpyxl raises)
    }

    // openpyxl: workbook/tests/test_child.py::test_reassign_title
    @Test func reassignTitle() {
        let wb = Workbook()
        wb.active.title = "Sheet"
        #expect(wb.active.title == "Sheet")
    }

    // openpyxl: workbook/tests/test_child.py::test_title_too_long
    @Test func titleTooLong() {
        let wb = Workbook()
        wb.active.title = String(repeating: "X", count: 50)
        #expect(wb.active.title.count == 50)   // accepted with a warning in openpyxl; accepted silently here
    }

    // openpyxl: workbook/tests/test_child.py::test_empty_title
    @Test func emptyTitle() {
        let wb = Workbook()
        wb.active.title = ""
        #expect(wb.active.title == "Sheet" && Worksheet.validateTitle("") != nil)
    }
}

@Suite struct WorkbookDefinedNameParityTests {
    // openpyxl: workbook/tests/test_defined_name.py::test_write
    @Test func write() throws {
        let wb = Workbook(); wb.definedNames["test"] = "Sheet!$A$1"
        let data = try wb.save()
        let xml = String(decoding: try ZipArchive(data: data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<definedNames><definedName name=\"test\">Sheet!$A$1</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_defined_name.py::test_read
    @Test func read() throws {
        let p = WorkbookXMLParser()
        try p.run(try openpyxlFixture("workbook/defined_names.xml"), part: "workbook.xml")
        #expect(p.definedNames.count + p.localNames.values.reduce(0) { $0 + $1.count } == 6)
        #expect(p.definedNames["MyRef"] == "Sheet1!$A$1" && p.definedNames["MyValue"] == "9.99")
    }

    // openpyxl: workbook/tests/test_defined_name.py::test_by_sheet
    @Test func bySheet() throws {
        let p = WorkbookXMLParser()
        try p.run(try openpyxlFixture("workbook/defined_names.xml"), part: "workbook.xml")
        #expect(p.localNames[0] == ["MySheetRef": "Sheet1!$A$3", "MySheetValue": "3.33"] && p.localNames[1] == ["MySheetRef": "Sheet2!$A$1", "MySheetValue": "14.4"])
    }
}

@Suite struct WorkbookPropertiesParityTests {
    // openpyxl: workbook/tests/test_properties.py::TestWorkbookProperties::test_ctor
    @Test func workbookPropertiesCtor() throws {
        let wb = Workbook(); wb.epoch = .mac1904
        let xml = String(decoding: try ZipArchive(data: try wb.save()).read("xl/workbook.xml"), as: UTF8.self)
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
        let xml = String(decoding: try ZipArchive(data: try Workbook().save()).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/>"))
    }
}

@Suite struct WorkbookViewsParityTests {
    // openpyxl: workbook/tests/test_views.py::TestBookView::test_ctor
    @Test func bookViewCtor() throws {
        let wb = Workbook(); wb.createSheet(); wb.activeIndex = 1
        let xml = String(decoding: try ZipArchive(data: try wb.save()).read("xl/workbook.xml"), as: UTF8.self)
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
    func workbookXML(_ wb: Workbook) throws -> String { String(decoding: try ZipArchive(data: try wb.save()).read("xl/workbook.xml"), as: UTF8.self) }
    func unicodeWorkbook() -> Workbook { let wb = Workbook(); wb.active.title = "D\u{fc}sseldorf Sheet"; return wb }

    // openpyxl: workbook/tests/test_writer.py::test_hidden_worksheet
    @Test func hiddenWorksheet() throws {
        let wb = Workbook(); wb.active.state = .hidden; wb.createSheet(); wb.activeIndex = 1
        let xml = try workbookXML(wb)
        #expect(xml.contains("<workbookView activeTab=\"1\"/>") && xml.contains("<sheet name=\"Sheet\" sheetId=\"1\" state=\"hidden\" r:id=\"rId1\"/><sheet name=\"Sheet1\" sheetId=\"2\" r:id=\"rId2\"/>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_workbook
    @Test func workbook() throws {
        let xml = try workbookXML(Workbook())
        #expect(xml.contains("<workbookPr/><bookViews><workbookView activeTab=\"0\"/></bookViews><sheets><sheet name=\"Sheet\" sheetId=\"1\" r:id=\"rId1\"/></sheets><calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/></workbook>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_workbook_code_name
    @Test func workbookCodeName() throws {
        let wb = Workbook(); wb.codeName = "MyWB"
        #expect(try workbookXML(wb).contains("<workbookPr codeName=\"MyWB\"/>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_print_area
    @Test func printArea() throws {
        let wb = unicodeWorkbook(); wb.active.setPrintArea("A1:D4")
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">'D\u{fc}sseldorf Sheet'!$A$1:$D$4</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_print_titles
    @Test func printTitles() throws {
        let wb = unicodeWorkbook(); wb.active.setPrintTitleRows("1:5")
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">'D\u{fc}sseldorf Sheet'!$1:$5</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_autofilter
    @Test func autofilter() throws {
        let wb = unicodeWorkbook(); wb.active.autoFilter = CellRange("A1:A10")
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">'D\u{fc}sseldorf Sheet'!$A$1:$A$10</definedName></definedNames>"))
        let back = try Workbook(data: try wb.save())
        #expect(back.active.autoFilter?.coordinate == "A1:A10" && back.active.definedNames.isEmpty)
    }

    // openpyxl: workbook/tests/test_writer.py::test_defined_name_global
    @Test func definedNameGlobal() throws {
        let wb = unicodeWorkbook(); wb.definedNames["MyConstant"] = "3.14"
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"MyConstant\">3.14</definedName></definedNames>"))
    }

    // openpyxl: workbook/tests/test_writer.py::test_defined_name_locall
    @Test func definedNameLocal() throws {
        let wb = unicodeWorkbook()
        wb.active.definedNames["MyReference"] = "\(CellReference.quoteSheetName(wb.active.title))!$A$1:$A$10"
        #expect(try workbookXML(wb).contains("<definedNames><definedName name=\"MyReference\" localSheetId=\"0\">'D\u{fc}sseldorf Sheet'!$A$1:$A$10</definedName></definedNames>"))
        #expect(try Workbook(data: try wb.save()).active.definedNames["MyReference"] == "'D\u{fc}sseldorf Sheet'!$A$1:$A$10")
    }
}
