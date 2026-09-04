import Foundation
#if canImport(FoundationXML)
import FoundationXML   // where Foundation is split, the XML parser lives in its own module
#endif
import SheetCore

/// Reads an XLSX / XLSM workbook one row at a time, without ever building it (openpyxl's `read_only=True`).
/// `StreamingReader` in the `SwiftSheets` module opens a file of any format and hands it to this reader when it
/// is an Excel workbook (spec Appendix B.40.1); the API is the same here.
///
/// `Workbook(contentsOf:)` holds every cell — a hundred to two hundred bytes each, so a million cells is a few
/// hundred megabytes. This reads the same file for its values without that: the file itself is memory-mapped, one
/// sheet part is expanded a piece at a time, and rows are handed to your closure as they are parsed and then let go.
///
///     let reader = try XLSXStreamingReader(contentsOf: url)
///     var total = 0
///     try reader.forEachRow(inSheet: "売上", valuesOnly: 3) { values in
///         if case .integer(let qty)? = values[2] { total += qty }
///     }
///
/// **What it costs.** The compressed file is mapped, not read, so it does not count. What does: the piece of the
/// sheet part in hand (256 KiB expanded), the shared-string table (which every reader must hold whole), and the
/// row in your hands. `ReadOptions.cellLimit` does not apply — nothing accumulates for it to bound.
///
/// **What it does not do.** Only values and (on request) formatting: no merges, no notes, no charts, nothing
/// preserved. Nothing is written back — for that, read the workbook the ordinary way.
public struct XLSXStreamingReader: StreamingRowSource {
    /// The most bytes of a sheet part held at once by the last walk — the number the memory promise rests on.
    nonisolated(unsafe) package static var lastLargestCarry = 0
    let zip: ZipArchive
    let sst: [CellValue]
    let styles: StylesParser
    let epoch: DateEpoch
    /// The sheets of the workbook, in the file's order.
    public let sheetNames: [String]
    private let partPaths: [String: String]

    /// Maps the file rather than reading it, so a workbook far larger than memory can be walked.
    public init(contentsOf url: URL, limits: ZipLimits = ZipLimits(), password: String? = nil) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe), limits: limits, password: password)
    }

    /// `limits` is what the container may declare about itself before it is refused (`ReadOptions.limits`);
    /// `password` opens a protected workbook (the package is decrypted whole first — a compound file cannot be
    /// walked a row at a time).
    public init(data: Data, limits: ZipLimits = ZipLimits(), password: String? = nil) throws {
        var data = data
        if let unopenable = UnopenableInput.probe(data) {
            guard unopenable == .encryptedOOXML, let password else { throw unopenable.error }
            data = try OOXMLEncryption.decrypt(data, password: password)
        }
        zip = try ZipArchive(data: data, limits: limits)
        let rootRels = (try? WorkbookReader.parseRels(zip, "_rels/.rels")) ?? []
        let workbookPath = rootRels.first { $0.type.hasSuffix(WorkbookReader.relOfficeDocument) }
            .map { WorkbookReader.resolvePart($0.target, relativeTo: "") } ?? "xl/workbook.xml"
        guard zip.contains(workbookPath) else { throw SheetError.malformedPart(path: workbookPath, detail: "workbook part missing") }
        let wbParser = WorkbookXMLParser()
        try wbParser.run(try zip.read(workbookPath), part: workbookPath)
        epoch = wbParser.date1904 ? .mac1904 : .windows1900

        let base = (workbookPath as NSString).deletingLastPathComponent
        let rels = (try? WorkbookReader.parseRels(zip, WorkbookReader.relsPath(of: workbookPath))) ?? []
        func resolve(_ target: String) -> String { WorkbookReader.resolvePart(target, relativeTo: base) }

        let sstPath = rels.first { $0.type.hasSuffix(WorkbookReader.relSharedStrings) }.map { resolve($0.target) } ?? "xl/sharedStrings.xml"
        let sstParser = SharedStringsParser()
        if zip.contains(sstPath) { try sstParser.run(stream: try zip.stream(sstPath), part: sstPath) }
        sst = sstParser.strings

        let stylesPath = rels.first { $0.type.hasSuffix(WorkbookReader.relStyles) }.map { resolve($0.target) } ?? "xl/styles.xml"
        let stylesParser = StylesParser()
        if zip.contains(stylesPath) { try stylesParser.run(try zip.read(stylesPath), part: stylesPath) }
        styles = stylesParser

        var names: [String] = []
        var paths: [String: String] = [:]
        for info in wbParser.sheets {
            guard let rel = rels.first(where: { $0.id == info.rId }) else { continue }
            names.append(info.name)
            paths[info.name] = resolve(rel.target)
        }
        guard !names.isEmpty else { throw SheetError.invalidWorkbook("workbook has no sheets") }
        sheetNames = names
        partPaths = paths
    }

    /// One grid per sheet: a worksheet is one table.
    public func tableCount(inSheet name: String) throws -> Int {
        guard partPaths[name] != nil else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        return 1
    }

    /// Visits every row of a sheet in order. Throwing from `body` stops the walk and rethrows. `table` is 0 —
    /// a worksheet is one grid — and exists so the call reads the same for every format.
    public func forEachRow(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: (StreamedRow) throws -> Void) throws {
        try checkTable(table, inSheet: name)
        guard let part = partPaths[name] else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        // the part is expanded a piece at a time and never held whole: what this reader costs is the piece in
        // hand, the shared strings, and the row on its way to the caller (spec Appendix B.39.8)
        let stream = try zip.stream(part)
        // the parser holds the closure only for the length of `run`, so a caller may pass a non-escaping one
        try withoutActuallyEscaping(body) { handler in
            let parser = StreamingSheetParser(sst: sst, styles: styles, epoch: epoch, options: options, body: handler)
            do {
                XLSXStreamingReader.lastLargestCarry = try parser.run(stream: stream, part: part)
            } catch {
                // the parser is stopped on purpose twice over: when the handler throws, and at the end of <sheetData>
                if let thrown = parser.thrown { throw thrown }
                if !parser.reachedEnd { throw error }
            }
            if let thrown = parser.thrown { throw thrown }
        }
    }

    /// The rows of a sheet as a sequence to iterate — `for try await row in reader.rows(inSheet: "売上")` — pulled
    /// one piece of the part at a time as the loop asks for them, so a walk that stops early reads no further
    /// (spec Appendix B.39.10). The rows arrive in the sheet's order; the sequence is asynchronous only because that
    /// is the shape Swift gives a sequence that can throw.
    public func rows(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions()) -> AsyncThrowingStream<StreamedRow, Error> {
        StreamingRowSequence.make { try rowWalk(inSheet: name, table: table, options: options) }
    }

    /// The pull shape of the walk: one piece of the part is expanded and parsed each time the rows in hand run out.
    package func rowWalk(inSheet name: String, table: Int, options: StreamingReadOptions) throws -> any StreamingRowWalk {
        try checkTable(table, inSheet: name)
        guard let part = partPaths[name] else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        let parser = StreamingSheetParser(sst: sst, styles: styles, epoch: epoch, options: options) { _ in }
        return try PieceFedRowWalk(parser: parser, stream: try zip.stream(part), part: part)
    }

    /// The same walk, as dense value arrays (openpyxl's `values_only=True`). `width` pads every row to that many
    /// columns so the rows line up.
    public func forEachRow(inSheet name: String, table: Int = 0, valuesOnly width: Int?,
                           options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: ([CellValue?]) throws -> Void) throws {
        try forEachRow(inSheet: name, table: table, options: options) { try body($0.values(width: width)) }
    }
}

/// worksheet XML → rows, one at a time. Nothing is kept between rows.
final class StreamingSheetParser: StreamingRowParser {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    /// What `body` threw, so `forEachRow` can rethrow it rather than the parser's own abort error.
    private(set) var thrown: Error?
    /// The end of `<sheetData>` was reached — the walk finished, and the abort that followed is not a failure.
    private(set) var reachedEnd = false

    private let sst: [CellValue]
    private let styles: StylesParser
    private let epoch: DateEpoch
    private let options: StreamingReadOptions
    private var body: (StreamedRow) throws -> Void
    /// Points the parser at another receiver — the walk's own queue, once the walk exists.
    func rebind(_ body: @escaping (StreamedRow) throws -> Void) { self.body = body }

    private var inSheetData = false
    private var currentRow = -1, lastColumn = -1
    private var cells: [StreamedCell] = []
    private var cellRef: CellRef?
    private var cellType = "", cellStyle = 0
    private var vText = "", fText = "", isText = ""
    private var inV = false, inF = false, inIS = false, inT = false
    private var isRuns: [TextRun] = [], isHasRuns = false, inR = false, inRPr = false, runText = "", runFont: FontAttributes?
    private var skipDepth = 0

    init(sst: [CellValue], styles: StylesParser, epoch: DateEpoch, options: StreamingReadOptions,
         body: @escaping (StreamedRow) throws -> Void) {
        self.sst = sst; self.styles = styles; self.epoch = epoch; self.options = options; self.body = body
    }

    func start(_ name: String, _ a: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        if name == "sheetData" { inSheetData = true; return }
        guard inSheetData else { return }        // merges, filters, drawings: not this reader's business
        switch name {
        case "row":
            if let r = a["r"], let n = SheetParser.rowNumber(r) { currentRow = n - 1 } else { currentRow += 1 }
            lastColumn = -1
            cells = []
        case "c":
            if let r = a["r"], let ref = CellRef(r) { cellRef = ref; if ref.row != currentRow { currentRow = ref.row } }
            else { cellRef = CellRef(row: currentRow, col: lastColumn + 1) }
            lastColumn = cellRef!.col
            cellType = a["t"] ?? "n"; cellStyle = Int(a["s"] ?? "0") ?? 0
            vText = ""; fText = ""; isText = ""; isRuns = []; isHasRuns = false
        case "v": inV = true
        case "f": inF = true
        case "is": inIS = true
        case "r" where inIS: inR = true; isHasRuns = true; runText = ""; runFont = nil
        case "rPr" where inIS: inRPr = true; runFont = FontAttributes()
        case "t" where inIS: inT = true
        case "rPh": skipDepth = 1
        case _ where inRPr: runFont?.apply(name, a)
        default: break
        }
    }

    func text(_ s: String) {
        if inV { vText += s } else if inF { fText += s }
        else if inT, skipDepth == 0 { if inR { runText += s } else { isText += s } }
    }

    func end(_ name: String) {
        if skipDepth > 0 { skipDepth -= 1; return }
        guard inSheetData else { return }
        switch name {
        case "v": inV = false
        case "f": inF = false
        case "t": inT = false
        case "rPr" where inIS: inRPr = false
        case "r" where inIS: isRuns.append(TextRun(runText, font: runFont?.font)); inR = false
        case "is": inIS = false
        case "c":
            guard let ref = cellRef else { return }
            let value = cellValue()
            let style = options.includeStyles ? styles.style(cellStyle) : nil
            cells.append(StreamedCell(ref: ref, value: value, style: style))
            cellRef = nil
        case "row":
            let row = StreamedRow(index: currentRow, cells: cells)
            cells = []
            guard options.includesEmptyRows || !row.isEmpty else { return }
            do { try body(row) } catch {
                thrown = error
                fail(.invalidWorkbook("the row handler stopped the walk"))
            }
        case "sheetData":
            inSheetData = false
            reachedEnd = true
            fail(.invalidWorkbook("streaming reader finished"))   // nothing after sheetData concerns this reader
        default: break
        }
    }

    private func cellValue() -> CellValue? {
        let cached = cachedValue()
        if options.dataOnly { return cached }
        if !fText.isEmpty { return .formula(FormulaExpr.parse(fText, dialect: .xlsx), cached: cached) }
        return cached
    }

    private func cachedValue() -> CellValue? {
        switch cellType {
        case "s":
            guard let i = Int(vText.trimmingCharacters(in: .whitespaces)), sst.indices.contains(i) else { return nil }
            return sst[i]
        case "inlineStr":
            if isHasRuns { return isRuns.contains { $0.font != nil } ? .richText(isRuns) : .text(isRuns.map(\.text).joined()) }
            return .text(isText)
        case "str": return .text(vText)
        case "b": return .bool(vText.trimmingCharacters(in: .whitespaces) == "1")
        case "e": return .error(vText)
        case "d": return ExcelDate.fromISO8601(vText)
        default:
            let raw = vText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let d = Double(raw) else { return nil }
            switch styles.numericKind(cellStyle) {
            case .duration: return ExcelDate.durationFromSerial(d).map { .duration($0) }
            case .date: return ExcelDate.fromSerial(d, epoch: epoch)
            case .plain: break
            }
            if !raw.contains("."), !raw.contains("E"), !raw.contains("e"), let i = Int(raw) { return .integer(i) }
            return .number(Decimal(string: raw, locale: nil).flatMap { $0.isNaN ? nil : $0 } ?? Decimal(d))
        }
    }
}

/// Writes a workbook one row at a time, without ever building it (openpyxl's `write_only=True`).
///
/// Rows go into the file as they arrive: the sheet's XML is compressed on the way past and never held, so a
/// workbook of any size costs the same handful of megabytes. What that buys is paid for in what it gives up —
/// this writes values and formatting and nothing else, and once a row is written it cannot be gone back to.
///
///     let writer = try StreamingWriter(url: url, sheetName: "売上")
///     try writer.append([.text("品目"), .text("数量")])
///     for record in records { try writer.append([.text(record.name), .integer(record.quantity)]) }
///     try writer.close()
///
/// **What it costs.** One row, the style table (a handful of entries), and the compressor's own window. Nothing
/// grows with the number of rows. Text goes into the cells themselves rather than into a shared table, so a file
/// with a great many repeated strings comes out larger than the ordinary writer's — that is the trade.
///
/// **What it does not do.** One grid per sheet and nothing beside it: no merges, no notes, no conditional formats,
/// no named tables, no pivot tables, no preserved parts. `close()` must be called, or the file is left truncated.
public final class StreamingWriter {
    private let zip: ZipFileWriter
    private let styles = StyleRegistry()
    private var sheets: [(name: String, path: String)] = []
    private var open = false
    private var row = 0
    private var closed = false
    private var epoch: DateEpoch

    /// Starts a workbook whose first sheet is `sheetName`.
    public init(url: URL, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900) throws {
        zip = try ZipFileWriter(url: url)
        self.epoch = epoch
        try startSheet(named: sheetName)
    }

    /// Finishes the sheet being written and starts another.
    public func addSheet(named name: String) throws {
        try finishSheet()
        try startSheet(named: name)
    }

    /// Appends a row of values, at whatever row comes next.
    public func append(_ values: [CellValue?]) throws {
        try append(values.map { value in var c = Cell(); c.value = value; return c })
    }

    /// Appends a row of cells, formatting and all.
    public func append(_ cells: [Cell]) throws {
        precondition(!closed, "the writer is closed")
        row += 1
        var xml = "<row r=\"\(row)\">"
        for (column, cell) in cells.enumerated() {
            guard cell.value != nil || cell.style != .default else { continue }
            let ref = CellRef(row: row - 1, col: column).a1
            let index = styles.index(for: cell)
            let style = index != 0 ? " s=\"\(index)\"" : ""
            switch cell.value {
            case nil: xml += "<c r=\"\(ref)\"\(style)/>"
            case .formula(let f, let cached)?:
                var t = "", v = ""
                if let cached { (t, v) = StreamingWriter.inlineValueXML(cached, epoch: epoch) }
                xml += "<c r=\"\(ref)\"\(style)\(t)><f>\(XML.esc(f.rendered(as: .xlsx)))</f>\(v)</c>"
            case let value?:
                let (t, v) = StreamingWriter.inlineValueXML(value, epoch: epoch)
                xml += "<c r=\"\(ref)\"\(style)\(t)>\(v)</c>"
            }
        }
        pending.append(contentsOf: (xml + "</row>").utf8)
        if pending.count >= StreamingWriter.pieceSize { try flushPending() }
    }

    /// Rows are handed to the compressor in pieces of about this many bytes: one call per row was measured slower
    /// than the whole-workbook writer, and the compressor works best on a window at a time.
    static let pieceSize = 64 * 1024
    private var pending = Data()
    private func flushPending() throws {
        guard !pending.isEmpty else { return }
        try zip.write(pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// Finishes the last sheet, writes the small parts beside it and closes the file. Calling it twice is harmless.
    public func close() throws {
        guard !closed else { return }
        closed = true
        try finishSheet()

        var ct = XMLWriter.header + "<Types xmlns=\"\(XMLWriter.nsContentTypes)\">"
        ct += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        ct += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ct += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"\(WorkbookWriter.ctWorkbook)\"/>"
        for sheet in sheets {
            ct += "<Override PartName=\"/\(sheet.path)\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        ct += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        ct += "<Override PartName=\"/\(Theme.partPath)\" ContentType=\"\(Theme.contentType)\"/>"
        ct += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        ct += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        try zip.add("[Content_Types].xml", Data((ct + "</Types>").utf8))

        var root = XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">"
        root += "<Relationship Id=\"rId1\" Type=\"\(XMLWriter.nsRel)/officeDocument\" Target=\"xl/workbook.xml\"/>"
        root += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        root += "<Relationship Id=\"rId3\" Type=\"\(XMLWriter.nsRel)/extended-properties\" Target=\"docProps/app.xml\"/>"
        try zip.add("_rels/.rels", Data((root + "</Relationships>").utf8))
        try zip.add("docProps/core.xml", Data((XMLWriter.header + WorkbookWriter.coreXML(DocumentProperties())).utf8))
        try zip.add("docProps/app.xml", Data((XMLWriter.header + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>\(SwiftSheetsInfo.name)</Application><AppVersion>\(SwiftSheetsInfo.appVersion)</AppVersion></Properties>").utf8))

        var wb = XMLWriter.header + "<workbook xmlns=\"\(XMLWriter.nsMain)\" xmlns:r=\"\(XMLWriter.nsRel)\">"
        wb += "<workbookPr\(epoch == .mac1904 ? " date1904=\"1\"" : "")/><bookViews><workbookView activeTab=\"0\"/></bookViews><sheets>"
        for (i, sheet) in sheets.enumerated() {
            wb += "<sheet name=\"\(XML.esc(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        wb += "</sheets><calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/></workbook>"
        try zip.add("xl/workbook.xml", Data(wb.utf8))

        var rels = XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">"
        for (i, sheet) in sheets.enumerated() {
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(XMLWriter.nsRel)/worksheet\" Target=\"\(XML.esc(WorkbookWriter.relativeTarget(sheet.path, from: "xl")))\"/>"
        }
        rels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"\(XMLWriter.nsRel)/styles\" Target=\"styles.xml\"/>"
        rels += "<Relationship Id=\"rId\(sheets.count + 2)\" Type=\"\(XMLWriter.nsRel)\(Theme.relationshipType)\" Target=\"\(XML.esc(WorkbookWriter.relativeTarget(Theme.partPath, from: "xl")))\"/>"
        try zip.add("xl/_rels/workbook.xml.rels", Data((rels + "</Relationships>").utf8))
        try zip.add(Theme.partPath, Data((XMLWriter.header + Theme.xml).utf8))
        try zip.add("xl/styles.xml", Data((XMLWriter.header + styles.xml()).utf8))
        try zip.finish()
    }

    deinit { if !closed { zip.abandon() } }

    private func startSheet(named name: String) throws {
        let path = "xl/worksheets/sheet\(sheets.count + 1).xml"
        sheets.append((name, path))
        row = 0
        try zip.beginEntry(path)
        try zip.write(XMLWriter.header + "<worksheet xmlns=\"\(XMLWriter.nsMain)\" xmlns:r=\"\(XMLWriter.nsRel)\"><sheetData>")
        open = true
    }

    private func finishSheet() throws {
        guard open else { return }
        try flushPending()
        try zip.write("</sheetData></worksheet>")
        try zip.endEntry()
        open = false
    }

    /// A value written into the cell itself. Text goes inline rather than into a shared table: a streaming writer
    /// cannot know at the first row which strings the last one will repeat.
    static func inlineValueXML(_ v: CellValue, epoch: DateEpoch) -> (t: String, body: String) {
        switch v {
        case .integer(let i): ("", "<v>\(i)</v>")
        case .number(let d): ("", "<v>\(XMLWriter.num(d))</v>")
        case .bool(let b): (" t=\"b\"", "<v>\(b ? 1 : 0)</v>")
        case .date(let dt): ("", "<v>\(XML.num(ExcelDate.toSerial(dt, epoch: epoch)))</v>")
        case .time(let t): ("", "<v>\(t.dayFraction)</v>")
        case .duration(let d): ("", "<v>\(XML.num(ExcelDate.toSerial(d)))</v>")
        case .error(let e): (" t=\"e\"", "<v>\(XML.esc(e))</v>")
        case .text(let s): (" t=\"inlineStr\"", "<is><t\(preserveSpace(s))>\(XML.esc(s))</t></is>")
        case .richText(let runs):
            (" t=\"inlineStr\"", "<is>" + runs.map { r in
                (r.font.map { StyleRegistry.fontXML($0, tag: "rPr", nameTag: "rFont") } ?? "").isEmpty
                    ? "<r><t\(preserveSpace(r.text))>\(XML.esc(r.text))</t></r>"
                    : "<r>\(StyleRegistry.fontXML(r.font!, tag: "rPr", nameTag: "rFont"))<t\(preserveSpace(r.text))>\(XML.esc(r.text))</t></r>"
            }.joined() + "</is>")
        case .formula: ("", "")
        }
    }

    private static func preserveSpace(_ t: String) -> String {
        (t.hasPrefix(" ") || t.hasSuffix(" ") || t.hasPrefix("　") || t.hasSuffix("　") || t.contains("\n") || t.contains("\t"))
            ? " xml:space=\"preserve\"" : ""
    }
}
