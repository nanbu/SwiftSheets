import Foundation
import Testing
@testable import SwiftSheets

@Suite struct CellParityTests {
    let wb = Workbook()   // keeps the sheet (and the cells' weak back-references) alive for the test
    func dummyCell() -> Cell { wb.active.cell(row: 1, column: 1) }

    // openpyxl: cell/tests/test_cell.py::test_ctor
    @Test func ctor() {
        let cell = dummyCell()
        #expect(cell.dataType == "n" && cell.column == 1 && cell.row == 1 && cell.coordinate == "A1" && cell.value == nil && cell.comment == nil)
    }

    // openpyxl: cell/tests/test_cell.py::test_null
    @Test(arguments: [CellValue.integer(1), .date(CivilDateTime(date: CivilDate(year: 2026, month: 1, day: 1)!)), .string("x"), .bool(true), .formula("=1", cached: nil), .error("#N/A")])
    func null(_ value: CellValue) {
        let cell = dummyCell()
        cell.value = value
        #expect(cell.dataType == value.dataType)
        cell.value = nil
        #expect(cell.dataType == "n")
    }

    // openpyxl: cell/tests/test_cell.py::test_string
    @Test(arguments: ["hello", ".", "0800"]) func string(_ value: String) {
        let cell = dummyCell()
        cell.value = CellValue(inferring: value)
        #expect(cell.dataType == "s" && cell.value == .string(value))
    }

    // openpyxl: cell/tests/test_cell.py::test_formula
    @Test(arguments: ["=42", "=if(A1<4;-1;1)"]) func formula(_ value: String) {
        let cell = dummyCell()
        cell.value = CellValue(inferring: value)
        #expect(cell.dataType == "f")
    }

    // openpyxl: cell/tests/test_cell.py::test_not_formula
    @Test func notFormula() {
        let cell = dummyCell()
        cell.value = CellValue(inferring: "=")
        #expect(cell.dataType == "s" && cell.value == .string("="))
    }

    // openpyxl: cell/tests/test_cell.py::test_boolean
    @Test(arguments: [true, false]) func boolean(_ value: Bool) {
        let cell = dummyCell()
        cell.value = .bool(value)
        #expect(cell.dataType == "b")
    }

    // openpyxl: cell/tests/test_cell.py::test_error_codes
    @Test(arguments: ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"]) func errorCodes(_ errorString: String) {
        let cell = dummyCell()
        cell.value = CellValue(inferring: errorString)
        #expect(cell.dataType == "e" && cell.value == .error(errorString))
    }

    static let insertDateCases: [(CellValue, String)] = [
        (.date(CivilDateTime(date: CivilDate(year: 2010, month: 7, day: 13)!, time: TimeOfDay(hour: 6, minute: 37, second: 41))), "yyyy-mm-dd h:mm:ss"),
        (CellValue(CivilDate(year: 2010, month: 7, day: 13)!), "yyyy-mm-dd"),
        (.time(TimeOfDay(hour: 1, minute: 3)), "h:mm:ss"),
    ]
    // openpyxl: cell/tests/test_cell.py::test_insert_date
    @Test(arguments: insertDateCases)
    func insertDate(_ value: CellValue, _ numberFormat: String) {
        let cell = dummyCell()
        cell.value = value
        #expect(cell.dataType == "d" && cell.isDate && cell.numberFormat == numberFormat)
    }

    // openpyxl: cell/tests/test_cell.py::test_time_format_datetime_subclass
    @Test func timeFormatDatetime() {
        let cell = dummyCell()
        cell.value = .date(CivilDateTime(date: CivilDate(year: 2018, month: 9, day: 5)!, time: TimeOfDay(hour: 0, minute: 0, second: 1)))
        #expect(cell.numberFormat == "yyyy-mm-dd h:mm:ss")
    }

    // openpyxl: cell/tests/test_cell.py::test_time_format_date_subclass
    @Test func timeFormatDate() {
        let cell = dummyCell()
        cell.value = CellValue(CivilDate(year: 2018, month: 9, day: 5)!)
        #expect(cell.numberFormat == "yyyy-mm-dd")
    }

    // openpyxl: cell/tests/test_cell.py::test_time_format_no_date_subclass
    @Test func timeFormatNoDate() {
        let cell = dummyCell()
        cell.value = .string("2018-09-05")
        #expect(cell.numberFormat == "General")   // only date-like values pick a time format
    }

    // openpyxl: cell/tests/test_cell.py::test_not_overwrite_time_format
    @Test func notOverwriteTimeFormat() {
        let cell = dummyCell()
        cell.numberFormat = "mmm-yy"
        cell.value = CellValue(CivilDate(year: 2010, month: 7, day: 13)!)
        #expect(cell.numberFormat == "mmm-yy")
    }

    static let formattedAsDateCases: [(CellValue?, Bool)] = [(nil, true), (.string("testme"), false), (.bool(true), false)]
    // openpyxl: cell/tests/test_cell.py::test_cell_formatted_as_date
    @Test(arguments: formattedAsDateCases)
    func cellFormattedAsDate(_ value: CellValue?, _ isDate: Bool) {
        let cell = dummyCell()
        cell.value = CellValue(CivilDate(year: 2026, month: 8, day: 22)!)
        cell.value = value
        #expect(cell.isDate == isDate && cell.value == value)
    }

    // openpyxl: cell/tests/test_cell.py::test_illegal_characters
    @Test func illegalCharacters() {
        // The bytes 0x00 through 0x1F (except tab, newline, carriage return) cannot appear in cell text.
        let illegal = Array(0..<9) + Array(11..<13) + Array(14..<32)
        for i in illegal {
            let ch = String(UnicodeScalar(UInt8(i)))
            #expect(CellValue.containsIllegalCharacters(ch) && CellValue.containsIllegalCharacters("A \(ch) B"))
            #expect(!XML.esc("A \(ch) B").contains(ch))   // and the writer drops them
        }
        for ok in [String(UnicodeScalar(33)), "\t", "\n", "\r", " Leading and trailing spaces are legal "] { #expect(!CellValue.containsIllegalCharacters(ok)) }
    }

    // openpyxl: cell/tests/test_cell.py::test_timedelta
    @Test func timedelta() {
        let cell = dummyCell()
        cell.value = .duration(.seconds(86400 + 3 * 3600))
        #expect(ExcelDate.toSerial(cell.value!) == 1.125 && cell.dataType == "d" && cell.isDate && cell.numberFormat == "[hh]:mm:ss")
    }

    // openpyxl: cell/tests/test_cell.py::<module>::test_repr
    @Test func repr() {
        let ws = wb.active; ws.title = "Dummy Worksheet"
        let cell = ws["A1"]
        #expect("<Cell '\(cell.worksheet!.title)'.\(cell.coordinate)>" == "<Cell 'Dummy Worksheet'.A1>")
    }

    // openpyxl: cell/tests/test_cell.py::test_comment_assignment
    @Test func commentAssignment() {
        let cell = dummyCell()
        #expect(cell.comment == nil)
        let comm = Comment("text", author: "author")
        cell.comment = comm
        #expect(cell.comment == comm)
    }

    // openpyxl: cell/tests/test_cell.py::test_only_one_cell_per_comment
    @Test func onlyOneCellPerComment() {
        let ws = wb.active
        let comm = Comment("text", author: "author")
        ws["A1"].comment = comm
        let c2 = ws.cell(row: 2, column: 1)
        c2.comment = comm
        #expect(c2.comment == comm && ws["A1"].comment == comm)   // value type: each cell owns its own copy
    }

    // openpyxl: cell/tests/test_cell.py::test_remove_comment
    @Test func removeComment() {
        let cell = dummyCell()
        cell.comment = Comment("text", author: "author")
        cell.comment = nil
        #expect(cell.comment == nil)
    }

    // openpyxl: cell/tests/test_cell.py::test_cell_offset
    @Test func cellOffset() {
        #expect(dummyCell().offset(row: 2, column: 1)?.coordinate == "B3")
    }

    // openpyxl: cell/tests/test_cell.py::test_font
    @Test func font() {
        let cell = dummyCell()
        cell.font = Font(bold: true)
        #expect(cell.font == Font(bold: true) && cell.style.font == Font(bold: true))
    }

    // openpyxl: cell/tests/test_cell.py::test_fill
    @Test func fill() {
        let cell = dummyCell()
        cell.fill = PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000"))
        #expect(cell.fill == PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000")))
    }

    // openpyxl: cell/tests/test_cell.py::test_border
    @Test func border() {
        let cell = dummyCell()
        cell.border = Border()
        #expect(cell.border == Border())
    }

    // openpyxl: cell/tests/test_cell.py::test_number_format
    @Test func numberFormat() {
        let cell = dummyCell()
        cell.numberFormat = "dd--hh--mm"
        #expect(cell.numberFormat == "dd--hh--mm")
    }

    // openpyxl: cell/tests/test_cell.py::test_alignment
    @Test func alignment() {
        let cell = dummyCell()
        cell.alignment = Alignment(wrapText: true)
        #expect(cell.alignment == Alignment(wrapText: true))
    }

    // openpyxl: cell/tests/test_cell.py::test_protection
    @Test func protection() {
        let cell = dummyCell()
        cell.protection = Protection(locked: false)
        #expect(cell.protection == Protection(locked: false))
    }

    // openpyxl: cell/tests/test_cell.py::test_remove_hyperlink
    @Test func removeHyperlink() {
        let cell = dummyCell()
        cell.hyperlink = Hyperlink(target: "http://test.com")
        cell.hyperlink = nil
        #expect(cell.hyperlink == nil)
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_value
    @Test func mergedValue() {
        let ws = wb.active
        ws["B2"].value = "gone"
        ws.mergeCells("A1:C3")
        #expect(ws["B2"].value == nil)   // non-anchor cells of a merge hold nothing
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_data_type
    @Test func mergedDataType() {
        let ws = wb.active
        ws.mergeCells("A1:C3")
        #expect(ws["B2"].dataType == "n")
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_comment
    @Test func mergedComment() {
        let ws = wb.active
        ws["B2"].comment = Comment("x")
        ws.mergeCells("A1:C3")
        #expect(ws["B2"].comment == nil)
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_coordinate
    @Test func mergedCoordinate() {
        let ws = wb.active
        ws.mergeCells("A1:C3")
        #expect(ws["A1"].coordinate == "A1" && ws.isMerged("A1"))
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_hyperlink
    @Test func mergedHyperlink() {
        let ws = wb.active
        ws["B2"].hyperlink = Hyperlink(target: "http://x")
        ws.mergeCells("A1:C3")
        #expect(ws["B2"].hyperlink == nil)
    }
}

@Suite struct CellWriterParityTests {
    let wb = Workbook()
    /// The `<c …>…</c>` element the writer produces for one cell.
    func writeCell(_ ws: Worksheet, _ ref: String) -> String {
        let xml = WorkbookWriter.sheetXML(ws, epoch: ws.workbook?.epoch ?? .windows1900, styles: StyleRegistry(), strings: SharedStringTable()).xml
        guard let r = xml.range(of: "<c r=\"\(ref)\"") else { return "" }
        let tail = xml[r.lowerBound...]
        if let close = tail.range(of: "</c>") { return String(tail[..<close.upperBound]) }
        return String(tail[..<tail.range(of: "/>")!.upperBound])
    }

    static let writeCellCases: [(CellValue?, String)] = [
        (.integer(9781231231230), "<c r=\"A1\"><v>9781231231230</v></c>"),
        (.number(3.14), "<c r=\"A1\"><v>3.14</v></c>"),
        (.integer(1234567890), "<c r=\"A1\"><v>1234567890</v></c>"),
        (.formula("=sum(1+1)", cached: nil), "<c r=\"A1\"><f>sum(1+1)</f></c>"),
        (.bool(true), "<c r=\"A1\" t=\"b\"><v>1</v></c>"),
        (.string("Hello"), "<c r=\"A1\" t=\"s\"><v>0</v></c>"),   // SwiftSheets always uses the shared string table
        (.string(""), "<c r=\"A1\" t=\"s\"><v>0</v></c>"),
        (nil, "<c r=\"A1\"/>"),
    ]
    // openpyxl: cell/tests/test_writer.py::test_write_cell
    @Test(arguments: writeCellCases)
    func writeCell(_ value: CellValue?, _ expected: String) {
        let ws = wb.active
        ws["A1"].value = value
        #expect(writeCell(ws, "A1") == expected)
    }

    static let writeDateCases: [(CellValue, String)] = [
        (CellValue(CivilDate(year: 2011, month: 12, day: 25)!), "<c r=\"A1\" s=\"1\"><v>40902</v></c>"),
        (.date(CivilDateTime(date: CivilDate(year: 2011, month: 12, day: 25)!, time: TimeOfDay(hour: 14, minute: 23, second: 55))), "<c r=\"A1\" s=\"1\"><v>40902.59994212963</v></c>"),
        (.time(TimeOfDay(hour: 14, minute: 15, second: 25)), "<c r=\"A1\" s=\"1\"><v>0.5940393518518519</v></c>"),
        (.duration(.seconds(86400 + 3) + .microseconds(15)), "<c r=\"A1\" s=\"1\"><v>1.000034722395833</v></c>"),
    ]
    // openpyxl: cell/tests/test_writer.py::test_write_date
    @Test(arguments: writeDateCases)
    func writeDate(_ value: CellValue, _ expected: String) {
        let ws = wb.active
        ws["A1"].value = value
        let xml = writeCell(ws, "A1")
        let num = Double(xml.split(separator: "<v>")[1].split(separator: "<")[0])!, want = Double(expected.split(separator: "<v>")[1].split(separator: "<")[0])!
        #expect(xml.hasPrefix("<c r=\"A1\" s=\"1\">") && abs(num - want) < 1e-9)
    }

    static let epochCases: [(DateEpoch, String)] = [(.windows1900, "<c r=\"A1\" s=\"1\"><v>40902</v></c>"), (.mac1904, "<c r=\"A1\" s=\"1\"><v>39440</v></c>")]
    // openpyxl: cell/tests/test_writer.py::test_write_epoch
    @Test(arguments: epochCases)
    func writeEpoch(_ epoch: DateEpoch, _ expected: String) {
        let wb = Workbook(); wb.epoch = epoch
        wb.active["A1"].value = CellValue(CivilDate(year: 2011, month: 12, day: 25)!)
        #expect(writeCell(wb.active, "A1") == expected)
    }

    // openpyxl: cell/tests/test_writer.py::test_write_hyperlink
    @Test func writeHyperlink() {
        let ws = wb.active
        ws["A1"].value = "test"; ws["A1"].hyperlink = Hyperlink(target: "http://www.test.com")
        let part = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable())
        #expect(part.xml.contains("<hyperlinks><hyperlink ref=\"A1\" r:id=\"rId1\"/></hyperlinks>") && part.rels?.contains("Target=\"http://www.test.com\"") == true)
    }

    static let attributeCases: [(CellValue, String, String)] = [
        (.string("test"), "<v>0</v>", " t=\"s\""), (.formula("=SUM(A1:A2)", cached: nil), "<f>SUM(A1:A2)</f>", ""), (CellValue(CivilDate(year: 2018, month: 8, day: 25)!), "<v>43337</v>", " s=\"1\""),
    ]
    // openpyxl: cell/tests/test_writer.py::test_attributes
    @Test(arguments: attributeCases)
    func attributes(_ value: CellValue, _ body: String, _ attrs: String) {
        let ws = wb.active
        ws["A1"].value = value
        #expect(writeCell(ws, "A1") == "<c r=\"A1\"\(attrs)>\(body)</c>")
    }

    // openpyxl: cell/tests/test_writer.py::test_whitespace
    @Test func whitespace() {
        let table = SharedStringTable()
        _ = table.index(for: .string("  whitespace   "))
        #expect(table.xml().contains("<si><t xml:space=\"preserve\">  whitespace   </t></si>"))
    }

    // openpyxl: cell/tests/test_writer.py::test_rich_text
    @Test func richText() {
        let table = SharedStringTable()
        let red = Font(color: .rgb("00FF0000"))
        _ = table.index(for: .richText([TextRun("red", font: red), TextRun(" is used, you can expect "), TextRun("danger", font: red)]))
        #expect(table.xml().contains("<si><r><rPr><color rgb=\"00FF0000\"/></rPr><t>red</t></r><r><t xml:space=\"preserve\"> is used, you can expect </t></r><r><rPr><color rgb=\"00FF0000\"/></rPr><t>danger</t></r></si>"))
    }
}

@Suite struct CellRichTextParityTests {
    // openpyxl: cell/tests/test_rich_text.py::test_ctor
    @Test func textBlockCtor() {
        let b = TextRun("text", font: Font(bold: true))
        #expect(b.text == "text" && b.font == Font(bold: true))
    }

    // openpyxl: cell/tests/test_rich_text.py::test_eq
    @Test func textBlockEq() {
        #expect(TextRun("text", font: Font(bold: true)) == TextRun("text", font: Font(bold: true)))
    }

    // openpyxl: cell/tests/test_rich_text.py::test_ne
    @Test func textBlockNe() {
        #expect(TextRun("text", font: Font(bold: true)) != TextRun("text", font: Font(italic: true)))
    }

    // openpyxl: cell/tests/test_rich_text.py::TestTextBlock::test_str
    @Test func textBlockStr() {
        #expect(CellValue.richText([TextRun("text", font: Font(bold: true))]).pythonString == "text")
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_create_single
    @Test func richTextCreateSingle() {
        let v = CellValue.richText([TextRun("ABC")])
        #expect(v.stringValue == "ABC")
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_create_multi
    @Test func richTextCreateMulti() {
        let v = CellValue.richText([TextRun("ABC"), TextRun("DEF"), TextRun("GHI")])
        if case .richText(let runs) = v { #expect(runs.count == 3 && runs[1].text == "DEF") } else { Issue.record("not rich text") }
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_create_text_block
    @Test func richTextCreateTextBlock() {
        let v = CellValue.richText([TextRun("ABC", font: Font(bold: true))])
        if case .richText(let runs) = v { #expect(runs[0].font?.bold == true) } else { Issue.record("not rich text") }
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_from_element_simple_text
    @Test func fromElementSimpleText() throws {
        let p = SharedStringsParser(); try p.run(Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>a\nb</t></si></sst>".utf8), part: "sst")
        #expect(p.strings == [.string("a\nb")])
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_from_element_rich_text_only_text
    @Test func fromElementRichTextOnlyText() throws {
        let p = SharedStringsParser(); try p.run(Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><r><t>a\nb</t></r></si></sst>".utf8), part: "sst")
        #expect(p.strings == [.string("a\nb")])   // runs without fonts collapse to plain text
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_from_element_rich_text_only_text_block
    @Test func fromElementRichTextOnlyTextBlock() throws {
        let p = SharedStringsParser(); try p.run(Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><r><rPr><b/></rPr><t>a\nb</t></r></si></sst>".utf8), part: "sst")
        #expect(p.strings == [.richText([TextRun("a\nb", font: Font(bold: true))])])
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_from_element_rich_text_mixed
    @Test func fromElementRichTextMixed() throws {
        let p = SharedStringsParser(); try p.run(Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><r><t>a</t></r><r><rPr><b/></rPr><t>b</t></r><r><t>c</t></r></si></sst>".utf8), part: "sst")
        #expect(p.strings == [.richText([TextRun("a"), TextRun("b", font: Font(bold: true)), TextRun("c")])])
    }

    // openpyxl: cell/tests/test_rich_text.py::TestCellRichText::test_str
    @Test func richTextStr() {
        #expect(CellValue.richText([TextRun("a"), TextRun("b", font: Font(bold: true)), TextRun("c")]).pythonString == "abc")
    }

    // openpyxl: cell/tests/test_rich_text.py::TestCellRichText::test_to_tree
    @Test func richTextToTree() {
        let t = SharedStringTable(); _ = t.index(for: .richText([TextRun("a"), TextRun("b", font: Font(bold: true)), TextRun("c")]))
        #expect(t.xml().contains("<si><r><t>a</t></r><r><rPr><b val=\"1\"/></rPr><t>b</t></r><r><t>c</t></r></si>"))
    }
}
