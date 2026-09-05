import Foundation
import SheetCore

/// Reads an OpenDocument spreadsheet one row at a time, without ever building it (spec Appendix B.40.2).
/// `StreamingReader` in the `SwiftSheets` module opens a file of any format and hands it to this reader when it
/// is an ODS package; the API is the same here.
///
/// An ODS keeps every sheet in one part, `content.xml`, so walking the third sheet means reading past the first
/// two — their markup is tokenised and thrown away, no cell of them is made. The part is expanded a piece at a
/// time; what the reader holds is the piece in hand, the style catalogue (the document's automatic styles come
/// before its tables in the same part) and the row on its way to the caller. A row the file writes once with
/// `number-rows-repeated` is delivered that many times, as the whole-workbook reader expands it; a run of empty
/// rows or cells past the padding threshold is not (the same rule, `ODSReader.paddingRepeat`).
///
/// **What it does not do.** Only values and (on request) formatting: no merges, no notes, no validations,
/// nothing preserved. Nothing is written back — for that, read the workbook the ordinary way.
public struct ODSStreamingReader: StreamingRowSource {
    /// The most bytes of the body held at once by the last walk — the number the memory promise rests on.
    nonisolated(unsafe) package static var lastLargestCarry = 0
    let zip: ZipArchive
    let catalog: ODSStyleCatalog
    /// The sheets of the document, in the file's order.
    public let sheetNames: [String]

    /// Maps the file rather than reading it, so a document far larger than memory can be walked.
    public init(contentsOf url: URL, limits: ZipLimits = ZipLimits()) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    /// `limits` is what the container may declare about itself before it is refused (`ReadOptions.limits`). A
    /// protected package is refused by name: the SheetDecrypt product decrypts its entries whole (an encrypted
    /// package cannot be walked a row at a time) and hands this reader the plain package.
    public init(data: Data, limits: ZipLimits = ZipLimits()) throws {
        let zip = try ZipArchive(data: data, limits: limits)
        guard zip.contains("content.xml") else { throw SheetError.malformedPart(path: "content.xml", detail: "content.xml missing from the package") }
        let manifest = ManifestParser()
        if zip.contains("META-INF/manifest.xml") { try? manifest.run(try zip.read("META-INF/manifest.xml"), part: "META-INF/manifest.xml") }
        // the manifest says which entries are encrypted (ODF 1.3 §4.3): the file is refused by name
        if !manifest.encryptedEntries.isEmpty { throw UnopenableInput.encryptedODF.error }
        self.zip = zip
        catalog = ODSStyleCatalog()
        if zip.contains("styles.xml") { try StylesPartParser(catalog: catalog).run(try zip.read("styles.xml"), part: "styles.xml") }
        // the sheet names, from one pass over the tags of the body — no cell is made
        var names: [String] = []
        var depth = 0
        let stream = try zip.stream("content.xml")
        try TagScanner.scan({ try stream.next() }, names: ["table"]) { tag in
            if tag.isEnd { depth -= 1 } else {
                depth += 1
                if depth == 1 { names.append(tag.attribute("table:name") ?? "Sheet\(names.count + 1)") }
            }
            return true
        }
        guard !names.isEmpty else { throw SheetError.invalidWorkbook("the spreadsheet has no tables") }
        sheetNames = names
    }

    /// One grid per sheet: an ODF table is one grid.
    public func tableCount(inSheet name: String) throws -> Int {
        guard sheetNames.contains(name) else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        return 1
    }

    private func tableIndex(of name: String) throws -> Int {
        guard let index = sheetNames.firstIndex(of: name) else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        return index
    }

    /// Visits every row of a sheet in order. Throwing from `body` stops the walk and rethrows. `table` is 0 —
    /// an ODF table is one grid — and exists so the call reads the same for every format.
    public func forEachRow(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: (StreamedRow) throws -> Void) throws {
        try checkTable(table, inSheet: name)
        let target = try tableIndex(of: name)
        let stream = try zip.stream("content.xml")
        try withoutActuallyEscaping(body) { handler in
            let parser = ODSStreamingParser(catalog: catalog, target: target, options: options, body: handler)
            do {
                ODSStreamingReader.lastLargestCarry = try parser.run(stream: stream, part: "content.xml")
            } catch {
                // the parser is stopped on purpose twice over: when the handler throws, and at the end of the table
                if let thrown = parser.thrown { throw thrown }
                if !parser.reachedEnd { throw error }
            }
            if let thrown = parser.thrown { throw thrown }
        }
    }

    /// The rows of a sheet as a sequence to iterate — `for try await row in reader.rows(inSheet: "売上")` — pulled
    /// one piece of the body at a time as the loop asks for them, so a walk that stops early reads no further.
    public func rows(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions()) -> AsyncThrowingStream<StreamedRow, Error> {
        StreamingRowSequence.make { try rowWalk(inSheet: name, table: table, options: options) }
    }

    package func rowWalk(inSheet name: String, table: Int, options: StreamingReadOptions) throws -> any StreamingRowWalk {
        try checkTable(table, inSheet: name)
        let parser = ODSStreamingParser(catalog: catalog, target: try tableIndex(of: name), options: options) { _ in }
        return try PieceFedRowWalk(parser: parser, stream: try zip.stream("content.xml"), part: "content.xml")
    }

    /// The same walk, as dense value arrays (openpyxl's `values_only=True`). `width` pads every row to that many
    /// columns so the rows line up.
    public func forEachRow(inSheet name: String, table: Int = 0, valuesOnly width: Int?,
                           options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: ([CellValue?]) throws -> Void) throws {
        try forEachRow(inSheet: name, table: table, options: options) { try body($0.values(width: width)) }
    }
}

/// content.xml → the rows of one table, one at a time. The styles sections feed the catalogue as the
/// whole-workbook reader's `ContentParser` does; the tables before the one asked for are skipped as subtrees; the
/// table after it is never reached — the parse is stopped at the end of the one asked for.
final class ODSStreamingParser: StreamingRowParser {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    private(set) var thrown: Error?
    private(set) var reachedEnd = false

    private let catalog: ODSStyleCatalog
    private let target: Int
    private let options: StreamingReadOptions
    private var body: (StreamedRow) throws -> Void

    private var depth = 0
    private var lenient = true
    private var sectionDepth = 0
    private var skipDepth = 0
    private var tableIndex = -1
    private var inTable = false
    private var columnCursor = 0
    private var rowCursor = 0
    private var columnDefaults: [(start: Int, end: Int, name: String)] = []

    private var inRow = false
    private var rowRepeat = 1
    private var rowCells: [(col: Int, value: CellValue?, style: CellStyle?)] = []
    private var rowHasContent = false
    private var cellCursor = 0

    private var inCell = false
    private var cellAttrs: [String: String] = [:]
    private var cellCovered = false
    private var cellText = ODSCellText()

    init(catalog: ODSStyleCatalog, target: Int, options: StreamingReadOptions, body: @escaping (StreamedRow) throws -> Void) {
        self.catalog = catalog; self.target = target; self.options = options; self.body = body
    }

    func rebind(_ body: @escaping (StreamedRow) throws -> Void) { self.body = body }

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 1 { lenient = !ODSAttr.usesStandardPrefixes(rootAttributes) }
        if sectionDepth > 0 { sectionDepth += 1; catalog.start(name, a); return }
        if depth == 2, ContentParser.sections.contains(name) { sectionDepth = 1; return }
        if skipDepth > 0 { skipDepth += 1; return }
        if inCell, cellText.start(name, a) { return }

        switch name {
        case "table":
            if inTable { skipDepth = 1; return }   // a sub-table inside a cell
            tableIndex += 1
            guard tableIndex == target else { skipDepth = 1; return }   // not the sheet asked for: skipped whole
            inTable = true
            columnCursor = 0; rowCursor = 0; columnDefaults = []
        case "table-column":
            guard inTable, !inRow else { return }
            let n = Swift.max(1, ODSAttr.int(a, "table:number-columns-repeated") ?? 1)
            if options.includeStyles, let d = ODSAttr.get(a, "table:default-cell-style-name"), d != "Default", columnCursor < ODSReader.maxColumns {
                columnDefaults.append((columnCursor, Swift.min(columnCursor + n, ODSReader.maxColumns) - 1, d))
            }
            columnCursor += n
        case "table-row":
            guard inTable else { return }
            inRow = true
            rowRepeat = Swift.max(1, ODSAttr.int(a, "table:number-rows-repeated") ?? 1)
            rowCells = []; rowHasContent = false; cellCursor = 0
        case "table-cell", "covered-table-cell":
            guard inRow else { return }
            inCell = true
            cellAttrs = a
            cellCovered = name == "covered-table-cell"
            cellText.reset()
        case "frame", "shapes", "forms", "custom-shape", "control", "g":
            skipDepth = 1
        default: break
        }
    }

    func text(_ s: String) {
        if sectionDepth > 1 { catalog.text(s); return }
        guard skipDepth == 0 else { return }
        if inCell { cellText.text(s) }
    }

    func end(_ name: String) {
        defer { depth -= 1 }
        if sectionDepth > 0 { sectionDepth -= 1; if sectionDepth > 0 { catalog.end(name) }; return }
        if skipDepth > 0 { skipDepth -= 1; return }
        if inCell, cellText.end(name) { return }
        switch name {
        case "table-cell", "covered-table-cell":
            guard inCell else { return }
            inCell = false
            finishCell()
        case "table-row":
            guard inRow else { return }
            inRow = false
            finishRow()
        case "table":
            guard inTable else { return }
            inTable = false
            reachedEnd = true
            fail(.invalidWorkbook("streaming reader finished"))   // the tables after this one are not this walk's
        default: break
        }
    }

    private func finishCell() {
        let a = cellAttrs
        let n = Swift.max(1, ODSAttr.int(a, "table:number-columns-repeated") ?? 1)
        defer { cellCursor += n }
        guard !cellCovered, cellCursor < ODSReader.maxColumns else { return }

        var value = cellText.value(from: a, lenient: lenient)
        if case .text? = value, cellText.hasStyledRuns { value = cellText.richText { catalog.cellStyle(named: $0).font } }
        if let formula = ODSAttr.get(a, "table:formula", lenient: lenient), !options.dataOnly {
            value = .formula(FormulaExpr.parse(formula, dialect: .ods), cached: value)
        }
        var style: CellStyle?
        if options.includeStyles {
            let styleName = ODSAttr.get(a, "table:style-name", lenient: lenient)
            if let styleName, styleName != "Default" { style = catalog.cellStyle(named: styleName) }
            else if let d = columnDefaults.first(where: { $0.start <= cellCursor && cellCursor <= $0.end }) { style = catalog.cellStyle(named: d.name) }
            else { style = .default }
        }
        // the whole-workbook reader's rule: a cell with something in it always counts; an empty styled cell counts
        // unless it is repeated so often that it is padding, not content
        let material = value != nil
        guard material || (style != nil && style != .default && n < ODSReader.paddingRepeat) else { return }
        if material { rowHasContent = true }
        let count = Swift.min(n, ODSReader.maxColumns - cellCursor)
        for i in 0..<count { rowCells.append((cellCursor + i, value, style)) }
    }

    private func finishRow() {
        defer { rowCursor += rowRepeat }
        guard rowCursor < ODSReader.maxRows else { return }
        var expand: Int
        if rowHasContent { expand = Swift.min(rowRepeat, ODSReader.maxRows - rowCursor) }
        else if options.includesEmptyRows, rowRepeat < ODSReader.paddingRepeat { expand = rowRepeat }
        else { expand = 0 }
        guard expand > 0 else { return }
        for r in rowCursor..<(rowCursor + expand) {
            let row = StreamedRow(index: r, cells: rowCells.map { StreamedCell(ref: CellRef(row: r, col: $0.col), value: $0.value, style: $0.style) })
            guard options.includesEmptyRows || !row.isEmpty else { continue }
            do { try body(row) } catch {
                thrown = error
                fail(.invalidWorkbook("the row handler stopped the walk"))
                return
            }
        }
    }
}
