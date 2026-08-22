import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

@Suite struct CellParityTests {
    // PORT-NOTE: `Cell` is a value type that no longer knows its sheet or position, so the openpyxl "dummy cell"
    // (A1 of a worksheet) is a bare `Cell()` — value / style / note assignments behave the same on the struct.
    func dummyCell() -> Cell { Cell() }

    // openpyxl: cell/tests/test_cell.py::test_ctor
    @Test func ctor() {
        // PORT-NOTE: position lives on `CellRef` now; the old `cell.column == 1 && cell.row == 1` is the 0-based ref of A1.
        let cell = dummyCell(), ref = CellRef(row: 0, col: 0)
        #expect(cell.dataType == "n" && ref.col == 0 && ref.row == 0 && ref.a1 == "A1" && cell.value == nil && cell.comment == nil)
    }

    // openpyxl: cell/tests/test_cell.py::test_null
    @Test(arguments: [CellValue.integer(1), .date(CivilDateTime(date: CivilDate(year: 2026, month: 1, day: 1)!)), .text("x"), .bool(true), Formula("=1"), .error("#N/A")])
    func null(_ value: CellValue) {
        var cell = dummyCell()
        cell.value = value
        #expect(cell.dataType == value.dataType)
        cell.value = nil
        #expect(cell.dataType == "n")
    }

    // openpyxl: cell/tests/test_cell.py::test_string
    @Test(arguments: ["hello", ".", "0800"]) func string(_ value: String) {
        var cell = dummyCell()
        cell.value = CellValue(inferring: value)
        #expect(cell.dataType == "s" && cell.value == .text(value))
    }

    // openpyxl: cell/tests/test_cell.py::test_formula
    @Test(arguments: ["=42", "=if(A1<4;-1;1)"]) func formula(_ value: String) {
        var cell = dummyCell()
        cell.value = CellValue(inferring: value)
        #expect(cell.dataType == "f")
    }

    // openpyxl: cell/tests/test_cell.py::test_not_formula
    @Test func notFormula() {
        var cell = dummyCell()
        cell.value = CellValue(inferring: "=")
        #expect(cell.dataType == "s" && cell.value == .text("="))
    }

    // openpyxl: cell/tests/test_cell.py::test_boolean
    @Test(arguments: [true, false]) func boolean(_ value: Bool) {
        var cell = dummyCell()
        cell.value = .bool(value)
        #expect(cell.dataType == "b")
    }

    // openpyxl: cell/tests/test_cell.py::test_error_codes
    @Test(arguments: ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"]) func errorCodes(_ errorString: String) {
        var cell = dummyCell()
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
        var cell = dummyCell()
        cell.value = value
        #expect(cell.dataType == "d" && cell.isDate && cell.numberFormat == numberFormat)
    }

    // openpyxl: cell/tests/test_cell.py::test_time_format_datetime_subclass
    @Test func timeFormatDatetime() {
        var cell = dummyCell()
        cell.value = .date(CivilDateTime(date: CivilDate(year: 2018, month: 9, day: 5)!, time: TimeOfDay(hour: 0, minute: 0, second: 1)))
        #expect(cell.numberFormat == "yyyy-mm-dd h:mm:ss")
    }

    // openpyxl: cell/tests/test_cell.py::test_time_format_date_subclass
    @Test func timeFormatDate() {
        var cell = dummyCell()
        cell.value = CellValue(CivilDate(year: 2018, month: 9, day: 5)!)
        #expect(cell.numberFormat == "yyyy-mm-dd")
    }

    // openpyxl: cell/tests/test_cell.py::test_time_format_no_date_subclass
    @Test func timeFormatNoDate() {
        var cell = dummyCell()
        cell.value = .text("2018-09-05")
        #expect(cell.numberFormat == "General")   // only date-like values pick a time format
    }

    // openpyxl: cell/tests/test_cell.py::test_not_overwrite_time_format
    @Test func notOverwriteTimeFormat() {
        var cell = dummyCell()
        cell.numberFormat = "mmm-yy"
        cell.value = CellValue(CivilDate(year: 2010, month: 7, day: 13)!)
        #expect(cell.numberFormat == "mmm-yy")
    }

    static let formattedAsDateCases: [(CellValue?, Bool)] = [(nil, true), (.text("testme"), false), (.bool(true), false)]
    // openpyxl: cell/tests/test_cell.py::test_cell_formatted_as_date
    @Test(arguments: formattedAsDateCases)
    func cellFormattedAsDate(_ value: CellValue?, _ isDate: Bool) {
        var cell = dummyCell()
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
        var cell = dummyCell()
        cell.value = .duration(.seconds(86400 + 3 * 3600))
        #expect(ExcelDate.toSerial(cell.value!) == 1.125 && cell.dataType == "d" && cell.isDate && cell.numberFormat == "[hh]:mm:ss")
    }

    // openpyxl: cell/tests/test_cell.py::<module>::test_repr
    @Test func repr() {
        // PORT-NOTE: cells no longer hold a back-reference to their sheet; the repr is composed from the sheet's name
        // (renamed through the workbook, as before) and the cell's `CellRef`.
        var wb = Workbook(); wb.sheets[0].name = "Dummy Worksheet"
        let ref = CellRef("A1")!
        #expect("<Cell '\(wb.sheets[0].name)'.\(ref.a1)>" == "<Cell 'Dummy Worksheet'.A1>")
    }

    // openpyxl: cell/tests/test_cell.py::test_comment_assignment
    @Test func commentAssignment() {
        var cell = dummyCell()
        #expect(cell.comment == nil)
        let comm = CellNote("text", author: "author")
        cell.comment = comm
        #expect(cell.comment == comm)
    }

    // openpyxl: cell/tests/test_cell.py::test_only_one_cell_per_comment
    @Test func onlyOneCellPerComment() {
        var wb = Workbook()
        let comm = CellNote("text", author: "author")
        wb.sheets[0][cell: "A1"].comment = comm
        wb.sheets[0][cell: CellRef(row: 1, col: 0)].comment = comm
        let c2 = wb.sheets[0][cell: CellRef(row: 1, col: 0)]
        #expect(c2.comment == comm && wb.sheets[0][cell: "A1"].comment == comm)   // value type: each cell owns its own copy
    }

    // openpyxl: cell/tests/test_cell.py::test_remove_comment
    @Test func removeComment() {
        var cell = dummyCell()
        cell.comment = CellNote("text", author: "author")
        cell.comment = nil
        #expect(cell.comment == nil)
    }

    // openpyxl: cell/tests/test_cell.py::test_cell_offset
    @Test func cellOffset() {
        #expect(CellRef(row: 0, col: 0).offset(rows: 2, cols: 1).a1 == "B3")
    }

    // openpyxl: cell/tests/test_cell.py::test_font
    @Test func font() {
        var cell = dummyCell()
        cell.font = Font(bold: true)
        #expect(cell.font == Font(bold: true) && cell.style.font == Font(bold: true))
    }

    // openpyxl: cell/tests/test_cell.py::test_fill
    @Test func fill() {
        var cell = dummyCell()
        cell.fill = PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000"))
        #expect(cell.fill == PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000")))
    }

    // openpyxl: cell/tests/test_cell.py::test_border
    @Test func border() {
        var cell = dummyCell()
        cell.border = Border()
        #expect(cell.border == Border())
    }

    // openpyxl: cell/tests/test_cell.py::test_number_format
    @Test func numberFormat() {
        var cell = dummyCell()
        cell.numberFormat = "dd--hh--mm"
        #expect(cell.numberFormat == "dd--hh--mm")
    }

    // openpyxl: cell/tests/test_cell.py::test_alignment
    @Test func alignment() {
        var cell = dummyCell()
        cell.alignment = Alignment(wrapText: true)
        #expect(cell.alignment == Alignment(wrapText: true))
    }

    // openpyxl: cell/tests/test_cell.py::test_protection
    @Test func protection() {
        var cell = dummyCell()
        cell.protection = Protection(locked: false)
        #expect(cell.protection == Protection(locked: false))
    }

    // openpyxl: cell/tests/test_cell.py::test_remove_hyperlink
    @Test func removeHyperlink() {
        var cell = dummyCell()
        cell.hyperlink = Hyperlink(target: "http://test.com")
        cell.hyperlink = nil
        #expect(cell.hyperlink == nil)
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_value
    @Test func mergedValue() {
        var ws = Workbook().sheets[0]
        ws["B2"] = "gone"
        ws.merge("A1:C3")
        #expect(ws["B2"] == nil)   // non-anchor cells of a merge hold nothing
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_data_type
    @Test func mergedDataType() {
        var ws = Workbook().sheets[0]
        ws.merge("A1:C3")
        #expect(ws[cell: "B2"].dataType == "n")
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_comment
    @Test func mergedComment() {
        var ws = Workbook().sheets[0]
        ws[cell: "B2"].comment = CellNote("x")
        ws.merge("A1:C3")
        #expect(ws[cell: "B2"].comment == nil)
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_coordinate
    @Test func mergedCoordinate() {
        // PORT-NOTE: `cell.coordinate` no longer exists (cells carry no position); the A1 text comes from `CellRef`.
        var ws = Workbook().sheets[0]
        ws.merge("A1:C3")
        #expect(CellRef("A1")!.a1 == "A1" && ws.isMerged("A1"))
    }

    // openpyxl: cell/tests/test_cell.py::TestMergedCell::test_hyperlink
    @Test func mergedHyperlink() {
        var ws = Workbook().sheets[0]
        ws[cell: "B2"].hyperlink = Hyperlink(target: "http://x")
        ws.merge("A1:C3")
        #expect(ws[cell: "B2"].hyperlink == nil)
    }
}

@Suite struct CellWriterParityTests {
    /// The `<c …>…</c>` element the writer produces for one cell.
    // PORT-NOTE: a `Sheet` no longer knows its workbook (`ws.workbook?.epoch`), so the epoch is passed in explicitly.
    func writeCell(_ ws: Sheet, _ ref: String, epoch: DateEpoch = .windows1900) -> String {
        let xml = WorkbookWriter.sheetXML(ws, epoch: epoch, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, comments: nil, sink: WarningSink()).xml
        guard let r = xml.range(of: "<c r=\"\(ref)\"") else { return "" }
        let tail = xml[r.lowerBound...]
        if let close = tail.range(of: "</c>") { return String(tail[..<close.upperBound]) }
        return String(tail[..<tail.range(of: "/>")!.upperBound])
    }

    static let writeCellCases: [(CellValue?, String)] = [
        (.integer(9781231231230), "<c r=\"A1\"><v>9781231231230</v></c>"),
        (.number(3.14), "<c r=\"A1\"><v>3.14</v></c>"),
        (.integer(1234567890), "<c r=\"A1\"><v>1234567890</v></c>"),
        // PORT-NOTE: openpyxl writes formula text verbatim; the new library parses formulas to an AST and canonicalizes
        // function names on emit, so `=sum(1+1)` is written as `SUM(1+1)` (same formula, upper-case name).
        (Formula("=sum(1+1)"), "<c r=\"A1\"><f>SUM(1+1)</f></c>"),
        (.bool(true), "<c r=\"A1\" t=\"b\"><v>1</v></c>"),
        (.text("Hello"), "<c r=\"A1\" t=\"s\"><v>0</v></c>"),   // SwiftSheets always uses the shared string table
        (.text(""), "<c r=\"A1\" t=\"s\"><v>0</v></c>"),
        (nil, "<c r=\"A1\"/>"),
    ]
    // openpyxl: cell/tests/test_writer.py::test_write_cell
    @Test(arguments: writeCellCases)
    func writeCell(_ value: CellValue?, _ expected: String) {
        var ws = Workbook().sheets[0]
        if let value { ws["A1"] = value }
        // PORT-NOTE: assigning nil through the subscript drops a default-styled cell, so an empty `<c r="A1"/>` can only
        // come from a cell placed directly in `cells` — the state the reader leaves for every `<c>` it saw.
        else { ws.cells[CellRef(row: 0, col: 0)] = Cell() }
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
        var ws = Workbook().sheets[0]
        ws["A1"] = value
        let xml = writeCell(ws, "A1")
        let num = Double(xml.split(separator: "<v>")[1].split(separator: "<")[0])!, want = Double(expected.split(separator: "<v>")[1].split(separator: "<")[0])!
        #expect(xml.hasPrefix("<c r=\"A1\" s=\"1\">") && abs(num - want) < 1e-9)
    }

    static let epochCases: [(DateEpoch, String)] = [(.windows1900, "<c r=\"A1\" s=\"1\"><v>40902</v></c>"), (.mac1904, "<c r=\"A1\" s=\"1\"><v>39440</v></c>")]
    // openpyxl: cell/tests/test_writer.py::test_write_epoch
    @Test(arguments: epochCases)
    func writeEpoch(_ epoch: DateEpoch, _ expected: String) {
        var wb = Workbook(); wb.epoch = epoch
        wb.activeSheet["A1"] = CellValue(CivilDate(year: 2011, month: 12, day: 25)!)
        #expect(writeCell(wb.activeSheet, "A1", epoch: wb.epoch) == expected)
    }

    // openpyxl: cell/tests/test_writer.py::test_write_hyperlink
    @Test func writeHyperlink() {
        var ws = Workbook().sheets[0]
        ws["A1"] = "test"; ws[cell: "A1"].hyperlink = Hyperlink(target: "http://www.test.com")
        let part = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, comments: nil, sink: WarningSink())
        #expect(part.xml.contains("<hyperlinks><hyperlink ref=\"A1\" r:id=\"rId1\"/></hyperlinks>") && part.rels?.contains("Target=\"http://www.test.com\"") == true)
    }

    static let attributeCases: [(CellValue, String, String)] = [
        (.text("test"), "<v>0</v>", " t=\"s\""), (Formula("=SUM(A1:A2)"), "<f>SUM(A1:A2)</f>", ""), (CellValue(CivilDate(year: 2018, month: 8, day: 25)!), "<v>43337</v>", " s=\"1\""),
    ]
    // openpyxl: cell/tests/test_writer.py::test_attributes
    @Test(arguments: attributeCases)
    func attributes(_ value: CellValue, _ body: String, _ attrs: String) {
        var ws = Workbook().sheets[0]
        ws["A1"] = value
        #expect(writeCell(ws, "A1") == "<c r=\"A1\"\(attrs)>\(body)</c>")
    }

    // openpyxl: cell/tests/test_writer.py::test_whitespace
    @Test func whitespace() {
        let table = SharedStringTable()
        _ = table.index(for: .text("  whitespace   "))
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
        #expect(v.textValue == "ABC")
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
        #expect(p.strings == [.text("a\nb")])
    }

    // openpyxl: cell/tests/test_rich_text.py::test_rich_text_from_element_rich_text_only_text
    @Test func fromElementRichTextOnlyText() throws {
        let p = SharedStringsParser(); try p.run(Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><r><t>a\nb</t></r></si></sst>".utf8), part: "sst")
        #expect(p.strings == [.text("a\nb")])   // runs without fonts collapse to plain text
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
