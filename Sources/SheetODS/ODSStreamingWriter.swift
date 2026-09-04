import Foundation
import SheetCore

/// Writes an OpenDocument spreadsheet one row at a time, without ever building it (spec Appendix B.42).
///
/// An ODS document is one part, `content.xml`, and the styles its cells wear come *before* the tables in it — so
/// the rows cannot go straight into the package the way an XLSX sheet's can. Each row is turned into XML as it
/// arrives, registering whatever styles it wears, and set aside; `close()` writes the head of the document, the
/// styles the rows turned out to need, and then each sheet's rows a piece at a time into the compressed entry.
/// What is set aside stays in memory while it is small and spills to a temporary file once it is not
/// (`TextSpill`), so memory stays a few megabytes whatever the row count; the disk holds the rows once,
/// uncompressed, until `close()` — the price of the one-part format.
///
///     let writer = try ODSStreamingWriter(url: url, sheetName: "売上")
///     try writer.append([.text("品目"), .text("数量")])
///     for record in records { try writer.append([.text(record.name), .integer(record.quantity)]) }
///     try writer.close()
///
/// **What it does not do.** One table per sheet and nothing beside it: no merges, no notes, no validations, no
/// conditional formats, no print setup. `close()` must be called, or nothing is written at all.
public final class ODSStreamingWriter: StreamingRowSink {
    private let url: URL
    private let styles = ODSStyleRegistry()
    private let sink = ODSWarningSink()
    private struct Pending {
        var name: String
        var rows: TextSpill
        var columns = 0      // the widest row's last cell, plus one
        var count = 0
    }
    private var sheets: [Pending] = []
    private var current: Pending
    private var closed = false
    /// What the format could not carry as asked: a number format ODF has no data style for, a colour it cannot
    /// name. Final once `close()` has run.
    public private(set) var warnings: [ConversionWarning] = []

    /// Starts a document whose first sheet is `sheetName`. Nothing touches `url` until `close()`.
    public init(url: URL, sheetName: String = "Sheet1") throws {
        self.url = url
        current = Pending(name: sheetName, rows: TextSpill())
    }

    /// Finishes the sheet being written and starts another.
    public func addSheet(named name: String) throws {
        precondition(!closed, "the writer is closed")
        sheets.append(current)
        current = Pending(name: name, rows: TextSpill())
    }

    /// Appends a row of cells, formatting and all, at whatever row comes next. Empty cells between values are
    /// written as repeated empty cells; empty cells after the last value are not written.
    public func append(_ cells: [Cell]) throws {
        precondition(!closed, "the writer is closed")
        var last = -1
        for (c, cell) in cells.enumerated() where cell.value != nil || cell.style != .default { last = c }
        var xml = "<table:table-row>"
        if last >= 0 {
            var empties = 0
            for c in 0...last {
                let cell = cells[c]
                if cell.value == nil, cell.style == .default { empties += 1; continue }
                if empties > 0 {
                    xml += empties == 1 ? "<table:table-cell/>" : "<table:table-cell table:number-columns-repeated=\"\(empties)\"/>"
                    empties = 0
                }
                xml += ODSWriter.cellXML(cell, at: CellRef(row: current.count, col: c), merge: nil, matrix: nil, validation: nil,
                                         sheet: current.name, styles: styles, sink: sink)
            }
        } else {
            xml += "<table:table-cell/>"   // a row holds at least one cell (ODF 1.3 §9.1.4)
        }
        xml += "</table:table-row>"
        current.rows.write(xml)
        current.columns = Swift.max(current.columns, last + 1)
        current.count += 1
    }

    /// Writes the package: `mimetype` first and stored, the manifest, then `content.xml` as one streamed entry —
    /// its head, the styles, and each sheet's rows copied out a piece at a time — and the small parts after it.
    /// Calling it twice is harmless.
    public func close() throws {
        guard !closed else { return }
        closed = true
        sheets.append(current)

        // the parts beside the body describe a workbook of these sheets and nothing more
        let names = sheets.map(\.name)
        let workbook = Workbook(sheets: names.map { Sheet(name: $0) })
        let page = ODSPageStyles.Page(Sheet(name: names[0]))
        let pages = [(layout: "pm1", master: "PageStyle1", page: page, sheet: names[0])]
        // the table styles are registered before the automatic styles are written out
        let tableStyles = sheets.map { _ in styles.table(display: true, masterPage: "PageStyle1") }

        let zip = try ZipFileWriter(url: url)
        try zip.add("mimetype", Data(ODSWriter.mimeType.utf8), stored: true)
        try zip.add("META-INF/manifest.xml", Data(ODSWriter.manifestXML(opaque: [:], mediaTypes: [:]).utf8))
        try zip.beginEntry("content.xml")
        var head = ODSWriter.xmlHeader + "<office:document-content"
            + ODSWriter.ns(["office", "style", "text", "table", "draw", "fo", "xlink", "dc", "meta", "number", "svg", "of", "calcext", "loext", "tableooo"])
            + " office:version=\"1.3\">"
        head += "<office:scripts/><office:font-face-decls>" + ODSWriter.fontFacesXML(styles.fonts) + "</office:font-face-decls>"
        head += "<office:automatic-styles>" + styles.xml() + "</office:automatic-styles>"
        head += "<office:body><office:spreadsheet>"
        try zip.write(head)
        for (i, sheet) in sheets.enumerated() {
            let columns = Swift.max(1, sheet.columns)
            var open = "<table:table table:name=\"\(XML.esc(sheet.name))\" table:style-name=\"\(tableStyles[i])\">"
            open += "<table:table-column\(columns > 1 ? " table:number-columns-repeated=\"\(columns)\"" : "") table:default-cell-style-name=\"Default\"/>"
            try zip.write(open)
            if sheet.count == 0 { try zip.write("<table:table-row><table:table-cell/></table:table-row>") }
            try sheet.rows.forEachPiece { try zip.write($0) }
            try zip.write("</table:table>")
        }
        try zip.write("</office:spreadsheet></office:body></office:document-content>")
        try zip.endEntry()
        try zip.add("styles.xml", Data(ODSWriter.stylesXML(styles.fonts, conditionalStyles: ODSConditionalStyleRegistry(), pages: pages, sink: sink).utf8))
        try zip.add("meta.xml", Data(ODSWriter.metaXML(DocumentProperties()).utf8))
        try zip.add("settings.xml", Data(ODSWriter.settingsXML(workbook).utf8))
        try zip.finish()

        // what the styles could not say — the same reports the whole-workbook writer makes
        if styles.nonRGBColour { sink.add(.degraded, subject: .formatting, "theme/indexed colours written as default") }
        if styles.gradientFill { sink.add(.substituted, subject: .formatting, "gradient fill(s) written as their first colour: an ODF cell style has one background colour") }
        for code in styles.unexpressibleCodes { sink.add(.substituted, subject: .formatting, "number format \(code) has no ODF data style; General used") }
        for code in styles.partialCodes { sink.add(.substituted, subject: .formatting, "number format \(code): only its first section is written") }
        warnings = sink.warnings
    }
}
