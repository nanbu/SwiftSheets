import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

/// Parses a styles.xml document (or a fragment wrapped in `<styleSheet>`) with the production parser.
func parseStyles(_ xml: String) throws -> StylesParser {
    let p = StylesParser()
    let doc = xml.contains("<styleSheet") || xml.contains("<x:styleSheet") ? xml : "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(xml)</styleSheet>"
    try p.run(Data(doc.utf8), part: "styles.xml")
    return p
}

func openpyxlFixture(_ path: String) throws -> Data {
    let parts = path.split(separator: "/").map(String.init)
    let file = parts.last!
    let dot = file.lastIndex(of: ".")!
    let url = Bundle.module.url(forResource: String(file[..<dot]), withExtension: String(file[file.index(after: dot)...]),
                                subdirectory: (["Fixtures", "openpyxl"] + parts.dropLast()).joined(separator: "/"))!
    return try Data(contentsOf: url)
}

func openpyxlFixtureText(_ path: String) throws -> String { String(decoding: try openpyxlFixture(path), as: UTF8.self) }

/// A one-sheet package built by hand so tests can omit or hand-write parts (styles, shared strings, rels).
func minimalPackage(sheet: String, styles: String? = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>",
                    sharedStrings: String? = nil, workbook: String? = nil, sheetRels: String? = nil) -> Data {
    let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main", rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    var z = ZipWriter()
    z.add("[Content_Types].xml", Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>".utf8))
    z.add("_rels/.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8))
    z.add("xl/workbook.xml", Data((workbook ?? "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets><sheet name=\"Sheet\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>").utf8))
    var rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
    if styles != nil { rels += "<Relationship Id=\"rId2\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/>" }
    if sharedStrings != nil { rels += "<Relationship Id=\"rId3\" Type=\"\(rel)/sharedStrings\" Target=\"sharedStrings.xml\"/>" }
    z.add("xl/_rels/workbook.xml.rels", Data((rels + "</Relationships>").utf8))
    if let styles { z.add("xl/styles.xml", Data(styles.utf8)) }
    if let sharedStrings { z.add("xl/sharedStrings.xml", Data(sharedStrings.utf8)) }
    if let sheetRels { z.add("xl/worksheets/_rels/sheet1.xml.rels", Data(sheetRels.utf8)) }
    let body = sheet.hasPrefix("<worksheet") ? sheet : "<worksheet xmlns=\"\(ns)\" xmlns:r=\"\(rel)\">\(sheet)</worksheet>"
    z.add("xl/worksheets/sheet1.xml", Data(body.utf8))
    return z.finish()
}

@Suite struct StylesNumberParityTests {
    // openpyxl: styles/tests/test_number_style.py::test_builtin_format
    @Test func builtinFormat() {
        #expect(NumberFormat.builtinCode(2) == "0.00")
    }

    // openpyxl: styles/tests/test_number_style.py::test_number_descriptor
    @Test func numberDescriptor() {
        #expect(CellStyle().numberFormat == "General")   // the default every cell starts with
    }

    // openpyxl: styles/tests/test_number_style.py::test_strip_quotes
    @Test(arguments: [("\"Y: \"#.000\"m\"", "#.000"), ("[Red]", ""), ("[$-404]e\"\u{fc}\"m\"\u{fc}\"d\"\u{fc}\"", "emd"), ("#,##0\\ [$\u{20bd}-46D]", "#,##0\\ ")])
    func stripQuotes(_ fmt: String, _ stripped: String) {
        #expect(NumberFormat.stripLiterals(fmt) == stripped)
    }

    static let dateFormatCases: [(String, Bool)] = [
        ("DD/MM/YY", true), ("H:MM:SS;@", true), ("#,##0\\ [$\u{20bd}-46D]", false), ("m\"M\"d\"D\";@", true), ("[h]:mm:ss", true),
        ("\"Y: \"0.00\"m\";\"Y: \"-0.00\"m\";\"Y: <num>m\";@", false), ("\"$\"#,##0_);[Red](\"$\"#,##0)", false),
        ("[$-404]e\"\u{fc}\"m\"\u{fc}\"d\"\u{fc}\"", true), ("0_ ;[Red]\\-0\\ ", false), ("\\Y000000", false), ("#,##0.0####\" YMD\"", false),
        ("[h]", true), ("[ss]", true), ("[s].000", true), ("[m]", true), ("[mm]", true), ("[Blue]\\+[h]:mm;[Red]\\-[h]:mm;[Green][h]:mm", true),
        ("[>=100][Magenta][s].00", true), ("[h]:mm;[=0]\\-", true), ("[>=100][Magenta].00", false), ("[>=100][Magenta]General", false),
        ("ha/p\\\\m", true), ("#,##0.00\\ _M\"H\"_);[Red]#,##0.00\\ _M\"S\"_)", false),
    ]
    // openpyxl: styles/tests/test_number_style.py::test_is_date_format
    @Test(arguments: dateFormatCases)
    func isDateFormat(_ format: String, _ result: Bool) {
        #expect(NumberFormat.isDateFormat(format) == result)
    }

    static let timedeltaCases: [(String, Bool)] = [
        ("m:ss", false), ("[h]", true), ("[hh]", true), ("[h]:mm:ss", true), ("[hh]:mm:ss", true), ("[h]:mm:ss.000", true), ("[hh]:mm:ss.0", true),
        ("[h]:mm", true), ("[hh]:mm", true), ("[m]:ss", true), ("[mm]:ss", true), ("[m]:ss.000", true), ("[mm]:ss.0", true), ("[s]", true), ("[ss]", true),
        ("[s].000", true), ("[ss].0", true), ("[m]", true), ("[mm]", true), ("h:mm", false), ("[Blue]\\+[h]:mm;[Red]\\-[h]:mm;[h]:mm", true),
        ("[Blue]\\+[h]:mm;[Red]\\-[h]:mm;[Green][h]:mm", true), ("[>=100][Magenta][s].00", true), ("[h]:mm;[=0]\\-", true),
        ("[>=100][Magenta].00", false), ("[>=100][Magenta]General", false),
    ]
    // openpyxl: styles/tests/test_number_style.py::test_is_timedelta_format
    @Test(arguments: timedeltaCases)
    func isTimedeltaFormat(_ format: String, _ result: Bool) {
        #expect(NumberFormat.isTimedeltaFormat(format) == result)
    }

    static let kindCases: [(String, NumberFormat.Kind)] = [
        (NumberFormat.dateDatetime, .datetime), (NumberFormat.dateDDMMYY, .date), (NumberFormat.dateDMMinus, .date), (NumberFormat.dateDMYSlash, .date),
        (NumberFormat.dateMYMinus, .date), (NumberFormat.dateTime1, .time), (NumberFormat.dateTime2, .time), (NumberFormat.dateTime3, .time), (NumberFormat.dateTime4, .time),
        (NumberFormat.dateTime5, .time), (NumberFormat.dateTime6, .time), (NumberFormat.dateTime7, .time), (NumberFormat.dateTime8, .time), (NumberFormat.dateTimedelta, .time),
        (NumberFormat.dateXLSX14, .date), (NumberFormat.dateXLSX15, .date), (NumberFormat.dateXLSX16, .date), (NumberFormat.dateXLSX17, .date), (NumberFormat.dateXLSX22, .datetime),
        (NumberFormat.dateYYMMDD, .date), (NumberFormat.dateYYMMDDSlash, .date), (NumberFormat.dateYYYYMMDD2, .date),
    ]
    // openpyxl: styles/tests/test_number_style.py::test_datetime
    @Test(arguments: kindCases)
    func datetimeKind(_ fmt: String, _ typ: NumberFormat.Kind) {
        #expect(NumberFormat.kind(of: fmt) == typ)
    }
}

@Suite struct StylesColorParityTests {
    // openpyxl: styles/tests/test_colors.py::test_argb
    @Test(arguments: ["00FFFFFF", "efefef"]) func argb(_ value: String) {
        if case .rgb(let v) = Color(hex: value) { #expect(v.count == 8 && v.allSatisfy(\.isHexDigit)) } else { Issue.record("expected rgb") }
    }

    // openpyxl: styles/tests/test_colors.py::test_rgb
    @Test func rgb() {
        #expect(Color(hex: "FFFFFFFF") == .rgb("FFFFFFFF"))
        #expect(StylesParser.color(["rgb": "ffffffff"]) == .rgb("FFFFFFFF"))
    }

    // openpyxl: styles/tests/test_colors.py::test_indexed
    @Test func indexed() {
        #expect(StylesParser.color(["indexed": "4"]) == .indexed(4))
        #expect(StyleRegistry.colorXML("color", .indexed(4)) == "<color indexed=\"4\"/>")
    }

    // openpyxl: styles/tests/test_colors.py::test_auto
    @Test func auto() {
        #expect(StylesParser.color(["auto": "1"]) == .auto)
        #expect(StyleRegistry.colorXML("color", .auto) == "<color auto=\"1\"/>")
    }

    // openpyxl: styles/tests/test_colors.py::test_theme
    @Test func theme() {
        #expect(StylesParser.color(["theme": "1"]) == .theme(1))
        #expect(StyleRegistry.colorXML("color", .theme(1)) == "<color theme=\"1\"/>")
    }

    // openpyxl: styles/tests/test_colors.py::test_tint
    @Test func tint() {
        #expect(StylesParser.color(["theme": "1", "tint": "0.5"]) == .theme(1, tint: 0.5))
        #expect(StyleRegistry.colorXML("color", .theme(1, tint: 0.5)) == "<color theme=\"1\" tint=\"0.5\"/>")
    }

    // openpyxl: styles/tests/test_colors.py::test_highlander
    @Test func highlander() {
        // When several attributes are present one wins, in the order rgb > theme > indexed > auto.
        #expect(StylesParser.color(["indexed": "4", "theme": "2", "auto": "0"]) == .theme(2, tint: 0))
        #expect(StylesParser.color(["indexed": "4", "auto": "0"]) == .indexed(4))
    }

    // openpyxl: styles/tests/test_colors.py::test_ctor_indexed
    @Test func colorListCtorIndexed() throws {
        let p = try parseStyles("<colors><indexedColors><rgbColor rgb=\"00FF0000\"/><rgbColor rgb=\"0000FF00\"/><rgbColor rgb=\"000000FF\"/></indexedColors></colors>")
        #expect(p.indexedColors == ["00FF0000", "0000FF00", "000000FF"])
    }

    // openpyxl: styles/tests/test_colors.py::test_write
    @Test func colorListWrite() {
        let reg = StyleRegistry(); reg.indexedColors = ["00FF0000", "0000FF00", "000000FF"]
        #expect(reg.xml().contains("<colors><indexedColors><rgbColor rgb=\"00FF0000\"/><rgbColor rgb=\"0000FF00\"/><rgbColor rgb=\"000000FF\"/></indexedColors></colors>"))
    }

    // openpyxl: styles/tests/test_colors.py::test_from_xml
    @Test func colorListFromXML() throws {
        let p = try parseStyles("<colors><indexedColors><rgbColor rgb=\"00FF0000\"></rgbColor><rgbColor rgb=\"0000FF00\"></rgbColor><rgbColor rgb=\"000000FF\"></rgbColor></indexedColors></colors>")
        #expect(p.indexedColors == ["00FF0000", "0000FF00", "000000FF"])
    }

    // openpyxl: styles/tests/test_colors.py::test_empty
    @Test func colorListEmpty() throws {
        #expect(try parseStyles("<colors/>").indexedColors.isEmpty)
    }

    // openpyxl: styles/tests/test_colors.py::test_no_colors
    @Test func colorListNoColors() {
        #expect(!StyleRegistry().xml().contains("<colors"))
    }
}

@Suite struct StylesFontParityTests {
    // openpyxl: styles/tests/test_fonts.py::test_ctor
    @Test func ctor() {
        let f = Font()
        #expect(f.name == nil && f.size == nil && !f.bold && !f.italic && f.underline == nil && !f.strikethrough && f.color == nil && f.vertAlign == nil && f.charset == nil)
    }

    // openpyxl: styles/tests/test_fonts.py::test_serialise
    @Test func serialise() {
        let xml = StyleRegistry.fontXML(Font.default)
        for piece in ["<name val=\"Calibri\"/>", "<family val=\"2\"/>", "<color theme=\"1\"/>", "<sz val=\"11\"/>", "<scheme val=\"minor\"/>"] { #expect(xml.contains(piece)) }
        #expect(xml.hasPrefix("<font>") && xml.hasSuffix("</font>"))
    }

    // openpyxl: styles/tests/test_fonts.py::test_create
    @Test func create() throws {
        let p = try parseStyles("""
        <fonts><font>
          <charset val="204"></charset><family val="2"></family><name val="Calibri"></name><sz val="11"></sz>
          <u val="single"/><vertAlign val="superscript"></vertAlign><color rgb="FF3300FF"></color>
        </font></fonts>
        """)
        var expected = Font(name: "Calibri", size: 11, underline: .single, color: .rgb("FF3300FF"))
        expected.charset = 204; expected.family = 2; expected.vertAlign = "superscript"
        #expect(p.fonts == [expected])
    }

    // openpyxl: styles/tests/test_fonts.py::test_nested_empty
    @Test func nestedEmpty() throws {
        let p = try parseStyles("<fonts><font><b /><u /><vertAlign /></font></fonts>")
        #expect(p.fonts == [Font(bold: true, underline: .single)])
    }
}

@Suite struct StylesFillParityTests {
    // openpyxl: styles/tests/test_fills.py::TestPatternFill::test_ctor
    @Test func patternCtor() {
        let f = PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000"), backgroundColor: .rgb("0000FF"))
        #expect(f.patternType == .solid && f.foregroundColor == .rgb("FF0000") && f.backgroundColor == .rgb("0000FF"))
    }

    // openpyxl: styles/tests/test_fills.py::TestPatternFill::test_dict_interface
    @Test func patternDictInterface() {
        let f = PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000"))
        #expect(f == PatternFill(patternType: .solid, foregroundColor: .rgb("FF0000"), backgroundColor: nil))
    }

    // openpyxl: styles/tests/test_fills.py::TestPatternFill::test_serialise
    @Test func patternSerialise() {
        let reg = StyleRegistry()
        var st = CellStyle(); st.fill = PatternFill(patternType: .solid, foregroundColor: .rgb("999999"), backgroundColor: .rgb("999999"))
        _ = reg.index(for: st)
        #expect(reg.xml().contains("<fill><patternFill patternType=\"solid\"><fgColor rgb=\"999999\"/><bgColor rgb=\"999999\"/></patternFill></fill>"))
    }

    static let createCases: [(String, PatternFill)] = [
        ("<fill><patternFill patternType=\"solid\"><fgColor theme=\"0\" tint=\"-0.14999847407452621\"/><bgColor indexed=\"64\"/></patternFill></fill>",
         PatternFill(patternType: .solid, foregroundColor: .theme(0, tint: -0.14999847407452621), backgroundColor: .indexed(64))),
        ("<fill><patternFill patternType=\"gray125\"/></fill>", PatternFill(patternType: .gray125)),
        ("<fill><patternFill patternType=\"solid\"><fgColor theme=\"0\" tint=\"-0.34998626667073579\"/><bgColor indexed=\"64\"/></patternFill></fill>",
         PatternFill(patternType: .solid, foregroundColor: .theme(0, tint: -0.34998626667073579), backgroundColor: .indexed(64))),
    ]
    // openpyxl: styles/tests/test_fills.py::TestPatternFill::test_create
    @Test(arguments: createCases)
    func patternCreate(_ src: String, _ expected: PatternFill) throws {
        #expect(try parseStyles("<fills>\(src)</fills>").fills == [expected])
    }

    // openpyxl: styles/tests/test_fills.py::test_create_empty_fill
    @Test func createEmptyFill() throws {
        #expect(try parseStyles("<fills><fill/></fills>").fills == [PatternFill()])
    }

    // openpyxl: styles/tests/test_fills.py::test_read_fills
    @Test func readFills() throws {
        let p = try parseStyles("""
        <fills count="3">
          <fill><patternFill/></fill>
          <fill><patternFill patternType="gray125"/></fill>
          <fill><patternFill patternType="solid"><fgColor theme="0" tint="-0.14999847407452621"/><bgColor indexed="64"/></patternFill></fill>
        </fills>
        """)
        #expect(p.fills.count == 3 && p.fills[1].patternType == .gray125 && p.fills[2].foregroundColor == .theme(0, tint: -0.14999847407452621))
    }
}

@Suite struct StylesBorderParityTests {
    // openpyxl: styles/tests/test_borders.py::test_create
    @Test func create() throws {
        let p = try parseStyles("""
        <borders><border>
          <left style="thin"><color rgb="FF006600"/></left>
          <right style="thin"><color rgb="FF006600"/></right>
          <top style="thin"><color rgb="FF006600"/></top>
          <bottom/>
        </border></borders>
        """)
        let bd = p.borders[0]
        #expect(bd.left.style == .thin && bd.right.color == .rgb("FF006600") && bd.bottom.style == nil && bd.diagonal == Side())
    }

    // openpyxl: styles/tests/test_borders.py::test_serialise
    @Test func serialise() {
        let mediumBlue = Side(style: .medium, color: .rgb("000000FF"))
        let bd = Border(left: mediumBlue, right: mediumBlue, top: mediumBlue, bottom: mediumBlue, diagonalDown: true, outline: false)
        let reg = StyleRegistry(); var st = CellStyle(); st.border = bd; _ = reg.index(for: st)
        let xml = reg.xml()
        #expect(xml.contains("<border diagonalDown=\"1\" outline=\"0\"><left style=\"medium\"><color rgb=\"000000FF\"/></left><right style=\"medium\"><color rgb=\"000000FF\"/></right><top style=\"medium\"><color rgb=\"000000FF\"/></top><bottom style=\"medium\"><color rgb=\"000000FF\"/></bottom><diagonal/></border>"))
    }
}

@Suite struct StylesAlignmentParityTests {
    // openpyxl: styles/tests/test_alignments.py::test_default
    @Test func defaultAlignment() {
        let al = Alignment()
        #expect(al == .none && al.horizontal == nil && al.vertical == nil && !al.wrapText && !al.shrinkToFit && al.indent == 0 && al.textRotation == 0)
    }

    // openpyxl: styles/tests/test_alignments.py::test_round_trip
    @Test func roundTrip() throws {
        let al = Alignment(horizontal: .center, vertical: .top, indent: 4, textRotation: 45)
        let reg = StyleRegistry(); var st = CellStyle(); st.alignment = al; _ = reg.index(for: st)
        #expect(reg.xml().contains("<alignment horizontal=\"center\" vertical=\"top\" indent=\"4\" textRotation=\"45\"/>"))
        let back = try parseStyles(reg.xml())
        #expect(back.cellXfs[1].alignment == al)
    }

    // openpyxl: styles/tests/test_alignments.py::test_alias
    @Test func alias() {
        let al = Alignment(wrapText: true, shrinkToFit: true, textRotation: 90)
        let reg = StyleRegistry(); var st = CellStyle(); st.alignment = al; _ = reg.index(for: st)
        #expect(reg.xml().contains("<alignment wrapText=\"1\" shrinkToFit=\"1\" textRotation=\"90\"/>"))
    }
}

@Suite struct StylesProtectionParityTests {
    // openpyxl: styles/tests/test_protection.py::test_default
    @Test func defaultProtection() {
        let pt = Protection()
        #expect(pt.locked && !pt.hidden)
    }

    // openpyxl: styles/tests/test_protection.py::test_round_trip
    @Test func roundTrip() throws {
        let pt = Protection(locked: true, hidden: true)
        let reg = StyleRegistry(); var st = CellStyle(); st.protection = pt; _ = reg.index(for: st)
        #expect(reg.xml().contains("<protection locked=\"1\" hidden=\"1\"/>"))
        #expect(try parseStyles(reg.xml()).cellXfs[1].protection == pt)
    }
}

@Suite struct StylesheetParityTests {
    // openpyxl: styles/tests/test_stylesheet.py::test_from_simple
    @Test func fromSimple() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/simple-styles.xml"))
        #expect(p.numFmts.count == 1 && p.numFmts[164] == "yyyy-mm-dd")
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_from_complex
    @Test func fromComplex() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/complex-styles.xml"))
        #expect(p.numFmts.isEmpty)
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_unprotected_cell
    @Test func unprotectedCell() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/worksheet_unprotected_style.xml"))
        #expect(p.cellXfs.count == 3)
        #expect(p.cellXfs[1].font == p.fonts[4] && p.cellXfs[1].protection == Protection())   // default is cells are locked
        #expect(p.cellXfs[2].font == p.fonts[3] && p.cellXfs[2].protection == Protection(locked: false))
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_read_cell_style
    @Test func readCellStyle() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/empty-workbook-styles.xml"))
        #expect(p.cellXfs.count == 2)
        #expect(p.cellXfs[1].numberFormat == "0%" && p.cellXfs[1].font == p.fonts[0])
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_read_xf_no_number_format
    @Test func readXfNoNumberFormat() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/no_number_format.xml"))
        #expect(p.cellXfs.count == 3)
        #expect(p.cellXfs[1].font == p.fonts[1] && p.cellXfs[1].border == p.borders[1] && p.cellXfs[1].numberFormat == "General")
        #expect(p.cellXfs[2].numberFormat == "mm-dd-yy")
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_none_values
    @Test func noneValues() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/none_value_styles.xml"))
        #expect(p.fonts[0].scheme == nil && p.fonts[0].vertAlign == nil && p.fonts[1].underline == nil)
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_alignment
    @Test func alignment() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/alignment_styles.xml"))
        #expect(p.cellXfs.count == 3)
        #expect(p.cellXfs.map(\.alignment) == [Alignment(), Alignment(textRotation: 180), Alignment(vertical: .top, textRotation: 255)])
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_rgb_colors
    @Test func rgbColors() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/rgb_colors.xml"))
        #expect(p.indexedColors.count == 64 && p.indexedColors.first == "00000000" && p.indexedColors.last == "00333333")
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_custom_number_formats
    @Test func customNumberFormats() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/styles_number_formats.xml"))
        #expect(Set(p.customNumberFormats) == ["_ * #,##0.00_ ;_ * \\-#,##0.00_ ;_ * \"-\"??_ ;_ @_ ", "#,##0.00_ ", "yyyy/m/d;@", "0.00000_ "])
        let dateStyles = p.cellXfs.indices.filter { NumberFormat.isDateFormat(p.cellXfs[$0].numberFormat) }
        #expect(dateStyles == [3])
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_remove_duplicate_number_formats
    @Test func removeDuplicateNumberFormats() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/builtins_as_custom_number_formats.xml"))
        #expect(p.customNumberFormats == ["dd\\/mm"])
        #expect(p.cellXfs[0].numberFormat == "General")
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_assign_number_formats
    @Test func assignNumberFormats() throws {
        let p = try parseStyles("""
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="1"><numFmt numFmtId="43" formatCode='_ * #,##0.00_ ;_ * \\-#,##0.00_ ;_ * "-"??_ ;_ @_ ' /></numFmts>
        <cellXfs count="0">
        <xf numFmtId="43" fontId="2" fillId="0" borderId="0" applyFont="0" applyFill="0" applyBorder="0" applyAlignment="0" applyProtection="0">
            <alignment vertical="center"/>
        </xf>
        </cellXfs>
        </styleSheet>
        """)
        #expect(p.cellXfs[0].numberFormat == "_ * #,##0.00_ ;_ * \\-#,##0.00_ ;_ * \"-\"??_ ;_ @_ " && p.cellXfs[0].alignment == Alignment(vertical: .center))
        // written back, the overridden builtin id becomes a custom id ≥ 164
        let reg = StyleRegistry(); _ = reg.index(for: p.cellXfs[0])
        #expect(reg.xml().contains("<numFmt numFmtId=\"164\""))
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_no_stylesheet
    @Test func noStylesheet() throws {
        let wb = try XLSXCodec.read(minimalPackage(sheet: "<sheetData><row r=\"1\"><c r=\"A1\" s=\"3\"><v>1</v></c></row></sheetData>", styles: nil)).workbook
        #expect(wb.activeSheet[cell: "A1"].style == .default && wb.activeSheet["A1"] == .integer(1))   // no styles part: every cell is default
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_no_styles
    @Test func noStyles() throws {
        let p = try parseStyles("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" />")
        #expect(p.cellXfs.isEmpty && p.style(0) == CellStyle())   // openpyxl warns and falls back to the defaults
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_write_worksheet
    @Test func writeWorksheet() {
        let reg = StyleRegistry(); reg.indexedColors = ["00000000", "00FFFFFF"]
        let xml = reg.xml()
        for piece in ["<fonts count=\"1\"><font><sz val=\"11\"/><color theme=\"1\"/><name val=\"Calibri\"/><family val=\"2\"/><scheme val=\"minor\"/></font></fonts>",
                      "<fills count=\"2\"><fill><patternFill/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>",
                      "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>",
                      "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>",
                      "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>",
                      "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>",
                      "<colors><indexedColors><rgbColor rgb=\"00000000\"/><rgbColor rgb=\"00FFFFFF\"/></indexedColors></colors>"] {
            #expect(xml.contains(piece), "missing \(piece)")
        }
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_simple_styles
    @Test func simpleStyles() throws {
        var ws = Workbook().activeSheet
        let today = CivilDate(year: 2026, month: 8, day: 22)!
        for v in ["12.34%", CellValue(today), "This is a test", "31.31415", nil] as [CellValue?] { ws.append([v]) }
        ws[cell: "D9"].numberFormat = NumberFormat.number00; ws[cell: "D9"].protection = Protection(locked: true)
        ws[cell: "E1"].protection = Protection(hidden: true)
        let reg = StyleRegistry()
        for ref in ["A1", "A2", "A3", "A4", "A5", "D9", "E1"] { _ = reg.index(for: ws[cell: ref].style) }   // same registration order as the reference
        let p = try parseStyles(reg.xml())
        #expect(p.cellXfs.count == 4)
        #expect(p.numFmts == [164: "yyyy-mm-dd"])
        #expect(p.cellXfs.map(\.numberFormat) == ["General", "yyyy-mm-dd", "0.00", "General"])
        #expect(p.cellXfs[3].protection == Protection(locked: true, hidden: true))
        let expected = try parseStyles(try openpyxlFixtureText("styles/simple-styles.xml"))
        #expect(p.cellXfs == expected.cellXfs && p.fonts == expected.fonts && p.fills == expected.fills && p.borders == expected.borders)
    }

    // openpyxl: styles/tests/test_stylesheet.py::test_no_default_style
    @Test func noDefaultStyle() throws {
        let p = try parseStyles(try openpyxlFixtureText("styles/no_default_styles.xml"))   // no <cellStyles> at all
        #expect(p.cellXfs.count == 4)
        #expect(StyleRegistry().xml().contains("<cellStyle name=\"Normal\""))   // the writer always supplies "Normal"
    }
}
