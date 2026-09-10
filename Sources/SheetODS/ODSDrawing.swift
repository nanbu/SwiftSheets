import Foundation
import SheetCore

/// A `draw:frame` as `content.xml` carries it, before the package parts it names are read (spec Appendix B.73):
/// in a cell (the anchor) or among the table's `table:shapes` (absolute), holding a picture (`draw:image`) or an
/// embedded object (`draw:object` — a chart document under `Object N/`).
struct ODSFrame {
    var sheetIndex: Int
    /// The cell the frame is anchored to; nil for a frame among `table:shapes`.
    var cell: CellRef?
    var imageHref: String?
    var objectHref: String?
    var width: Double?, height: Double?      // cm
    var x: Double?, y: Double?               // cm, offset from the anchor
    var endCell: String?                     // `table:end-cell-address`
    var endX: Double?, endY: Double?         // cm
}

/// `Object N/content.xml` → `Chart` (B.73): the chart's class names the kind (`chart:bar` with the plot area's
/// `chart:vertical` → column / bar, `chart:line`, `chart:circle` → pie; any other class stays as the raw kind),
/// the categories come from the x axis, the series from their cell-range addresses, the title from its text.
final class ODFChartParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    private var chartClass: String?
    private var styleVertical: [String: Bool] = [:]
    private var currentStyle: String?
    private var plotStyle: String?
    private var inTitle = false, titleText = ""
    private var legend = false
    private var categories: String?
    private var series: [Chart.Series] = []
    private var depthInPlot = 0
    private var inPlot = false

    var chart: Chart? {
        guard let chartClass else { return nil }
        let kind: Chart.Kind
        switch chartClass {
        case "chart:bar": kind = (plotStyle.flatMap { styleVertical[$0] } ?? false) ? .bar : .column
        case "chart:line": kind = .line
        case "chart:circle": kind = .pie
        default: kind = Chart.Kind(rawValue: chartClass)
        }
        var c = Chart(kind, title: titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : titleText.trimmingCharacters(in: .whitespacesAndNewlines))
        c.legend = legend
        c.series = series.map { var s = $0; if s.categories == nil { s.categories = categories }; return s }
        return c
    }

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "style": currentStyle = ODSAttr.get(a, "style:name")
        case "chart-properties":
            if let currentStyle, let v = ODSAttr.bool(a, "chart:vertical") { styleVertical[currentStyle] = v }
        case "chart": chartClass = ODSAttr.get(a, "chart:class")
        case "title" where !inPlot: inTitle = true; titleText = ""
        case "legend" where !inPlot: legend = true
        case "plot-area": inPlot = true; plotStyle = ODSAttr.get(a, "chart:style-name")
        case "categories" where inPlot:
            if let addr = ODSAttr.get(a, "table:cell-range-address") { categories = ContentParser.excelAddress(addr) }
        case "series" where inPlot:
            let values = ODSAttr.get(a, "chart:values-cell-range-address").map(ContentParser.excelAddress) ?? ""
            let label = ODSAttr.get(a, "chart:label-cell-address").map(ContentParser.excelAddress)
            series.append(Chart.Series(values: values, categories: nil, name: nil, nameReference: label))
        default: break
        }
    }
    func text(_ s: String) { if inTitle { titleText += s } }
    func end(_ name: String) {
        switch name {
        case "style": currentStyle = nil
        case "title" where inTitle: inTitle = false
        case "plot-area": inPlot = false
        default: break
        }
    }
}

enum ODSDrawing {
    /// The frames of `content.xml` resolved against the package: pictures into `SheetImage`s, chart objects into
    /// `Chart`s, per sheet. `consumed` lists the parts read into the model, which the package sweep must skip.
    static func resolve(_ frames: [ODSFrame], sheets: [Sheet], read: (String) throws -> Data?, exists: (String) -> Bool,
                        allNames: [String]) throws -> (images: [[SheetImage]], charts: [[Chart]], consumed: Set<String>, warnings: [ConversionWarning]) {
        var images = Array(repeating: [SheetImage](), count: sheets.count)
        var charts = Array(repeating: [Chart](), count: sheets.count)
        var consumed = Set<String>()
        var warnings: [ConversionWarning] = []
        for frame in frames where sheets.indices.contains(frame.sheetIndex) {
            let sheet = sheets[frame.sheetIndex]
            if let href = frame.objectHref {
                // an embedded object; the draw:image beside it is only LibreOffice's preview of it
                let dir = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                let content = dir + "/content.xml"
                guard exists(content), let data = try read(content) else { continue }
                let parser = ODFChartParser()
                guard (try? parser.run(data, part: content)) != nil, var chart = parser.chart else { continue }   // not a chart: stays an opaque object
                chart.anchor = chartRange(frame, sheet: sheet)
                charts[frame.sheetIndex].append(chart)
                for name in allNames where name.hasPrefix(dir + "/") || name == "ObjectReplacements/" + dir { consumed.insert(name) }
            } else if let href = frame.imageHref {
                let path = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                guard exists(path), let data = try read(path) else { continue }   // a linked picture outside the package stays a link
                guard var image = try? SheetImage(data: data) else {
                    warnings.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet.name,
                                                      message: "a picture in a format the model cannot hold (\((path as NSString).pathExtension)) is carried as a part only"))
                    continue
                }
                image.anchor = imageAnchor(frame, image: image, sheet: sheet)
                images[frame.sheetIndex].append(image)
                consumed.insert(path)
            }
        }
        return (images, charts, consumed, warnings)
    }

    static func imageAnchor(_ f: ODSFrame, image: SheetImage, sheet: Sheet) -> SheetImage.Anchor {
        let pt = { (cm: Double) in cm / 2.54 * 72 }
        guard let cell = f.cell else {
            return .absolute(x: pt(f.x ?? 0), y: pt(f.y ?? 0), width: pt(f.width ?? 0), height: pt(f.height ?? 0))
        }
        if let range = spanRange(f, from: cell) { return .span(range) }
        guard let w = f.width, let h = f.height else { return .cell(cell, sizing: .original) }
        let px = (Int((w / 2.54 * 96).rounded()), Int((h / 2.54 * 96).rounded()))
        return .cell(cell, sizing: px == (image.pixelWidth, image.pixelHeight) ? .original : .scaled(width: px.0, height: px.1))
    }

    /// The range a chart frame covers: to its end cell, or the cells its size reaches over from the anchor.
    static func chartRange(_ f: ODSFrame, sheet: Sheet) -> CellRange {
        let cell = f.cell ?? cellAt(x: f.x ?? 0, y: f.y ?? 0, sheet: sheet)
        if let range = spanRange(f, from: cell) { return range }
        var right = cell.column, bottom = cell.row, x = 0.0, y = 0.0
        let w = f.width ?? 0, h = f.height ?? 0
        while x + columnCm(right, sheet) < w, right < CellRef.maxColumn { x += columnCm(right, sheet); right += 1 }
        while y + rowCm(bottom, sheet) < h, bottom < CellRef.maxRow { y += rowCm(bottom, sheet); bottom += 1 }
        return CellRange(from: cell, to: CellRef(row: bottom, column: right))
    }

    /// `table:end-cell-address` with `end-x` / `end-y` of 0 names the cell past the frame (this writer's own form);
    /// any offset means the frame reaches into that cell.
    private static func spanRange(_ f: ODSFrame, from cell: CellRef) -> CellRange? {
        guard let endText = f.endCell, let end = CellRef(ContentParser.excelAddress(endText).split(separator: "!").last.map(String.init) ?? endText) else { return nil }
        let exclusive = (f.endX ?? 0) == 0 && (f.endY ?? 0) == 0
        let last = CellRef(row: max(exclusive ? end.row - 1 : end.row, cell.row), column: max(exclusive ? end.column - 1 : end.column, cell.column))
        return CellRange(from: cell, to: last)
    }

    static func columnCm(_ column: Int, _ sheet: Sheet) -> Double {
        (sheet.columnDimensions[column]?.width ?? CellPixels.defaultColumnWidth) * ODSLength.millimetresPerCharacter / 10
    }
    static func rowCm(_ row: Int, _ sheet: Sheet) -> Double {
        (sheet.rowDimensions[row]?.height ?? CellPixels.defaultRowHeight) * 2.54 / 72
    }
    /// The size of a cell range in centimetres, as this writer describes its columns and rows.
    static func rangeSize(_ range: CellRange, in sheet: Sheet) -> (width: Double, height: Double) {
        var width = 0.0, height = 0.0
        for c in range.minColumn...range.maxColumn { width += columnCm(c, sheet) }
        for r in range.minRow...range.maxRow { height += rowCm(r, sheet) }
        return (width, height)
    }
    private static func cellAt(x: Double, y: Double, sheet: Sheet) -> CellRef {
        var column = 1, cx = 0.0
        while cx + columnCm(column, sheet) <= x, column < CellRef.maxColumn { cx += columnCm(column, sheet); column += 1 }
        var row = 1, cy = 0.0
        while cy + rowCm(row, sheet) <= y, row < CellRef.maxRow { cy += rowCm(row, sheet); row += 1 }
        return CellRef(row: row, column: column)
    }

    // MARK: - Writing a chart as an embedded object

    /// A chart on its way into the package: its object directory and the frame in its anchor cell.
    struct ChartObject {
        let chart: Chart
        let directory: String      // "Object 3"
        let number: Int
        let zIndex: Int
        var anchor: CellRef { chart.anchor?.topLeft ?? CellRef(row: 1, column: 1) }
        var contentPath: String { directory + "/content.xml" }
    }

    static let chartMediaType = "application/vnd.oasis.opendocument.chart"

    /// `draw:frame` + `draw:object` for a chart, written in the anchor cell (B.73).
    static func frameXML(_ object: ChartObject, in sheet: Sheet) -> String {
        let range = object.chart.anchor ?? CellRange(from: object.anchor, to: object.anchor)
        let size = rangeSize(range, in: sheet)
        let end = CellRef(row: range.maxRow + 1, column: range.maxColumn + 1)
        return "<draw:frame draw:z-index=\"\(object.zIndex)\" draw:name=\"Chart \(object.number)\""
            + " svg:width=\"\(ODSLength.cmValue(size.width))\" svg:height=\"\(ODSLength.cmValue(size.height))\" svg:x=\"0cm\" svg:y=\"0cm\""
            + " table:end-cell-address=\"\(XML.esc(ODSFeatures.address(end, sheet: sheet.name)))\" table:end-x=\"0cm\" table:end-y=\"0cm\">"
            + "<draw:object xlink:href=\"./\(XML.esc(object.directory))\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>"
            + "</draw:frame>"
    }

    /// The chart document (`Object N/content.xml`): the class, the title, the legend, one x axis carrying the
    /// categories, one y axis, and the series with their ranges as ODF addresses. `sheetName` qualifies an
    /// unqualified series range, as the XLSX chart writer does.
    static func contentXML(_ chart: Chart, sheetName: String, size: (width: Double, height: Double)) -> String {
        let ns = ODSWriter.ns(["office", "style", "text", "table", "draw", "chart", "svg", "xlink", "fo"])
        let odsClass: String
        switch chart.kind {
        case .column, .bar: odsClass = "chart:bar"
        case .line: odsClass = "chart:line"
        case .pie: odsClass = "chart:circle"
        default: odsClass = chart.kind.rawValue.hasPrefix("chart:") ? chart.kind.rawValue : "chart:bar"
        }
        var s = ODSWriter.xmlHeader + "<office:document-content" + ns + " office:version=\"1.3\">"
        s += "<office:automatic-styles>"
        s += "<style:style style:name=\"plot\" style:family=\"chart\"><style:chart-properties chart:vertical=\"\(chart.kind == .bar)\" chart:three-dimensional=\"false\"/></style:style>"
        s += "<style:style style:name=\"ser\" style:family=\"chart\"><style:chart-properties chart:symbol-type=\"none\"/></style:style>"
        s += "</office:automatic-styles><office:body><office:chart>"
        s += "<chart:chart svg:width=\"\(ODSLength.cmValue(size.width))\" svg:height=\"\(ODSLength.cmValue(size.height))\" xlink:href=\"..\" xlink:type=\"simple\" chart:class=\"\(odsClass)\">"
        if let title = chart.title { s += "<chart:title><text:p>\(XML.esc(title))</text:p></chart:title>" }
        if chart.legend { s += "<chart:legend chart:legend-position=\"end\"/>" }
        s += "<chart:plot-area chart:style-name=\"plot\">"
        s += "<chart:axis chart:dimension=\"x\" chart:name=\"primary-x\">"
        if let cats = chart.series.first?.categories, let addr = address(cats, sheet: sheetName) {
            s += "<chart:categories table:cell-range-address=\"\(XML.esc(addr))\"/>"
        }
        s += "</chart:axis><chart:axis chart:dimension=\"y\" chart:name=\"primary-y\"/>"
        for series in chart.series {
            s += "<chart:series chart:style-name=\"ser\" chart:class=\"\(odsClass)\""
            if let addr = address(series.values, sheet: sheetName) { s += " chart:values-cell-range-address=\"\(XML.esc(addr))\"" }
            if let ref = series.nameReference, let addr = address(ref, sheet: sheetName) { s += " chart:label-cell-address=\"\(XML.esc(addr))\"" }
            s += "/>"
        }
        s += "</chart:plot-area></chart:chart></office:chart></office:body></office:document-content>"
        return s
    }

    /// `'Data'!$B$2:$B$4` or `B2:B4` → `Data.B2:Data.B4`; nil for a reference the model cannot read as a range.
    static func address(_ ref: String, sheet: String) -> String? {
        let bare = ref.replacingOccurrences(of: "$", with: "")
        guard let range = CellRange(bare) ?? CellRef(bare).map({ CellRange(from: $0, to: $0) }) else { return nil }
        return ODSFeatures.address(range, sheet: range.sheet ?? sheet)
    }
}
