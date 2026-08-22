import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Named cell styles — `cellStyles` / `cellStyleXfs` and the `xfId` a cell's `xf` points home with. Appendix B.7
/// listed them as未着手 and the README as a known limit of the preservation: a workbook opened and saved lost the
/// link, so Excel stopped showing the style as applied even though the formatting was still right.
@Suite struct NamedStyleTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

    // openpyxl: styles/tests/test_named_style.py::TestNamedCellStyleList::test_from_xml
    // openpyxl: styles/tests/test_named_style.py::TestNamedCellStyle::test_from_xml
    @Test func readsTheStylesAFileDeclares() throws {
        let wb = try Workbook(data: try Self.fixture("named-styles.xlsx"))
        #expect(wb.namedStyles.map(\.name) == ["Normal", "Heading X", "Title"])
        #expect(wb.namedStyle("Normal")?.builtinID == 0)
        #expect(wb.namedStyle("Title")?.builtinID == 15)
        #expect(wb.namedStyle("Heading X")?.builtinID == nil)

        let heading = try #require(wb.namedStyle("Heading X"))
        #expect(heading.style.font.bold)
        #expect(heading.style.font.size == 14)
        #expect(heading.style.fill.foregroundColor == .rgb("FFDDEBF7"))   // openpyxl writes fgColor only
        #expect(heading.style.numberFormat == "0.00")
        #expect(heading.style.alignment.horizontal == .center)
        #expect(heading.style.border.bottom.style == .thin)
    }

    @Test func cellsCarryTheirLink() throws {
        let sheet = try Workbook(data: try Self.fixture("named-styles.xlsx")).sheets[0]
        #expect(sheet[cell: "A1"].style.namedStyle == "Heading X")
        #expect(sheet[cell: "B1"].style.namedStyle == "Title")
        #expect(sheet[cell: "A3"].style.namedStyle == nil)      // "Normal" reads as no link, as openpyxl's does
        // a cell may keep the link and still override part of the formatting
        #expect(sheet[cell: "A2"].style.namedStyle == "Heading X")
        #expect(sheet[cell: "A2"].style.font.italic)
        #expect(!sheet[cell: "A2"].style.font.bold)
        #expect(sheet[cell: "A2"].style.fill.foregroundColor == .rgb("FFDDEBF7"))   // …the rest still comes from the style
    }

    @Test func linksSurviveAWriteBack() throws {
        let source = try Self.fixture("named-styles.xlsx")
        var wb = try Workbook(data: source)
        wb.sheets[0]["A4"] = "added"
        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.namedStyles == wb.namedStyles)
        #expect(again.sheets[0][cell: "A1"].style.namedStyle == "Heading X")
        #expect(again.sheets[0][cell: "B1"].style.namedStyle == "Title")
        #expect(again.sheets[0][cell: "A2"].style.font.italic)
        #expect(again.sheets[0][cell: "A2"].style.namedStyle == "Heading X")
    }

    /// A file's own `cellStyleXfs` indices must not move: `cellStyles` names them, and an entry no name points at
    /// still occupies its slot.
    @Test func sourceIndicesAreNotRenumbered() throws {
        let wb = try Workbook(data: try Self.fixture("named-styles.xlsx"))
        let tables = try #require(wb.preserved.styleTables)
        #expect(tables.namedStyleXfIndex["Normal"] == 0)
        #expect(tables.cellStyleXfs.count == 3)

        let written = try Package.part("xl/styles.xml", of: try wb.data(as: .xlsx))
        #expect(written.contains("<cellStyle name=\"Heading X\" xfId=\"1\""))
        #expect(written.contains("<cellStyle name=\"Title\" xfId=\"2\" builtinId=\"15\""))
        #expect(written.contains("<cellStyleXfs count=\"3\">"))
    }

    // openpyxl: styles/tests/test_named_style.py::TestNamedStyleList::test_append_valid
    // openpyxl: styles/tests/test_named_style.py::TestNamedStyleList::test_names
    @Test func aNewWorkbookCanDeclareOne() throws {
        var wb = Workbook()
        #expect(wb.namedStyles == [.normal])
        var accent = CellStyle()
        accent.font.bold = true
        accent.fill = .solid(.rgb("FFFFF2CC"))
        accent.numberFormat = "#,##0"
        wb.addNamedStyle(NamedStyle(name: "強調", style: accent))
        wb.sheets[0]["A1"] = 1000
        wb.sheets[0][cell: "A1"].style = NamedStyle(name: "強調", style: accent).applied

        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.namedStyles.map(\.name) == ["Normal", "強調"])
        #expect(again.namedStyle("強調")?.style.numberFormat == "#,##0")
        #expect(again.namedStyle("強調")?.style.fill == .solid(.rgb("FFFFF2CC")))
        #expect(again.sheets[0][cell: "A1"].style.namedStyle == "強調")
    }

    /// Editing a style the file already had rewrites its `cellStyleXfs` entry in place rather than appending one.
    @Test func editingAStyleKeepsItsSlot() throws {
        var wb = try Workbook(data: try Self.fixture("named-styles.xlsx"))
        let i = try #require(wb.namedStyles.firstIndex { $0.name == "Heading X" })
        wb.namedStyles[i].style.font.size = 22
        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.namedStyle("Heading X")?.style.font.size == 22)
        #expect(again.namedStyles.map(\.name) == ["Normal", "Heading X", "Title"])
    }

    /// The read side has to survive a styles.xml nobody wrote by hand: a name declared twice, an `xfId` that names
    /// nothing, and one half of the pair missing.
    // openpyxl: styles/tests/test_named_style.py::TestNamedCellStyleList::test_duplicate_names
    @Test func aMalformedStyleTableDegradesRatherThanMisleads() throws {
        func workbook(styles: String) throws -> Workbook {
            var package = try Self.fixture("named-styles.xlsx")
            package = try Package.repacking(package, replacing: "xl/styles.xml", with: Data(styles.utf8))
            return try Workbook(data: package)
        }
        let base = """
        <?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">        <fonts count="1"><font><sz val="11"/></font></fonts>        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>        <borders count="1"><border/></borders>
        """
        let duplicated = try workbook(styles: base + """
        <cellStyleXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="1"/></cellXfs>        <cellStyles count="3"><cellStyle name="Normal" xfId="0" builtinId="0"/><cellStyle name="Twice" xfId="1"/><cellStyle name="Twice" xfId="0"/></cellStyles>        </styleSheet>
        """)
        #expect(duplicated.namedStyles.map(\.name) == ["Normal", "Twice"])
        #expect(duplicated.namedStyle("Twice")?.style.numberFormat == "0.00")   // the first entry won

        let dangling = try workbook(styles: base + """
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="99"/></cellXfs>        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>        </styleSheet>
        """)
        #expect(dangling.sheets[0][cell: "A1"].style.namedStyle == nil)

        let halfATable = try workbook(styles: base + """
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>        <cellStyles count="2"><cellStyle name="Normal" xfId="0" builtinId="0"/><cellStyle name="Orphan" xfId="4"/></cellStyles>        </styleSheet>
        """)
        #expect(halfATable.namedStyles.map(\.name) == ["Normal", "Orphan"])
        #expect(halfATable.sheets[0][cell: "A1"].style.namedStyle == nil)
        #expect(try halfATable.data(as: .xlsx).count > 0)   // and still writes
    }

    // openpyxl: styles/tests/test_named_style.py::TestNamedStyleList::test_key
    // openpyxl: styles/tests/test_named_style.py::TestNamedStyleList::test_key_error
    @Test func lookingUpAStyleByName() {
        var wb = Workbook()
        wb.addNamedStyle(NamedStyle(name: "Accent"))
        #expect(wb.namedStyle("Accent")?.name == "Accent")
        #expect(wb.namedStyle("Nope") == nil)          // openpyxl raises KeyError; Swift answers nil
        wb.addNamedStyle(NamedStyle(name: "Accent", builtinID: 7))
        #expect(wb.namedStyles.count == 2 && wb.namedStyle("Accent")?.builtinID == 7)   // same name replaces
    }

    /// A link to a name the workbook does not declare is written as "Normal" rather than a dangling `xfId`.
    @Test func anUnknownLinkFallsBackToNormal() throws {
        var wb = Workbook()
        var st = CellStyle(); st.namedStyle = "Nowhere"; st.font.bold = true
        wb.sheets[0]["A1"] = 1
        wb.sheets[0][cell: "A1"].style = st
        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[0][cell: "A1"].style.namedStyle == nil)
        #expect(again.sheets[0][cell: "A1"].style.font.bold)
    }
}

/// Reading one part out of a package, for tests that want to look at the XML we generated.
enum Package {
    static func part(_ name: String, of data: Data) throws -> String {
        guard let d = try ZipInspection(data: data).entry(named: name) else {
            throw SheetError.malformedPart(path: name, detail: "missing")
        }
        return String(decoding: d, as: UTF8.self)
    }

    /// The same package with one part swapped out, for tests that need a file no writer would produce.
    static func repacking(_ data: Data, replacing name: String, with replacement: Data) throws -> Data {
        let source = try ZipInspection(data: data)
        var writer = ZipWriter()
        for entry in source.entryNames {
            writer.add(entry, entry == name ? replacement : (source.entry(named: entry) ?? Data()), stored: entry == "mimetype")
        }
        return writer.finish()
    }
}
