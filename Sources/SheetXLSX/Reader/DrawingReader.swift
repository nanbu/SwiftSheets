import Foundation
import SheetCore

/// What a sheet's drawing part holds, read into the model (spec Appendix B.72): pictures into `Sheet.images`,
/// charts into `Sheet.charts`, and a note of whatever else was there (shapes, pictures in a format the model
/// cannot hold, charts whose part could not be read) so the writer knows the part says more than the model.
struct DrawingContents {
    var images: [SheetImage] = []
    var charts: [Chart] = []
    /// Anchors the model has no word for, by their element (`sp`, `grpSp`, `cxnSp`, …) or a reason.
    var unmodelled: [String] = []
    /// The parts the drawing referenced (media, charts), so a rebuild can retire them.
    var referencedParts: [String] = []
}

/// One anchor of `xdr:wsDr`, as the SAX pass collects it.
struct DrawingAnchor {
    enum Kind { case picture(relID: String), chart(relID: String), other(String), none }
    enum Shape { case oneCell, twoCell, absolute }
    var shape: Shape
    var kind: Kind = .none
    var from = (column: 0, row: 0, columnOffset: 0, rowOffset: 0)
    var to = (column: 0, row: 0, columnOffset: 0, rowOffset: 0)
    var ext: (cx: Int, cy: Int)?
    var pos: (x: Int, y: Int)?
}

/// xl/drawings/drawingN.xml → anchors. Element names arrive without prefixes; the relationship ids are looked up
/// by any prefix (`r:embed`, `r:id`).
final class DrawingParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    private(set) var anchors: [DrawingAnchor] = []
    private var current: DrawingAnchor?
    private var corner: String?          // "from" / "to"
    private var field: String?           // col / colOff / row / rowOff
    private var buffer = ""
    private var inGraphicFrame = false

    private static func rel(_ a: [String: String], _ name: String) -> String? {
        a["r:" + name] ?? a.first { $0.key.hasSuffix(":" + name) }?.value ?? a[name]
    }

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "oneCellAnchor": current = DrawingAnchor(shape: .oneCell)
        case "twoCellAnchor": current = DrawingAnchor(shape: .twoCell)
        case "absoluteAnchor": current = DrawingAnchor(shape: .absolute)
        case "from", "to": corner = name
        case "col", "colOff", "row", "rowOff": if corner != nil { field = name; buffer = "" }
        case "ext":
            if current != nil, !inGraphicFrame, let cx = Int(a["cx"] ?? ""), let cy = Int(a["cy"] ?? "") { current?.ext = (cx, cy) }
        case "pos":
            if let x = Int(a["x"] ?? ""), let y = Int(a["y"] ?? "") { current?.pos = (x, y) }
        case "pic": if case .none? = current?.kind { current?.kind = .other("pic") }   // becomes .picture at the blip
        case "blip":
            if let id = Self.rel(a, "embed"), case .other("pic")? = current?.kind { current?.kind = .picture(relID: id) }
        case "graphicFrame": inGraphicFrame = true
        case "chart":
            if inGraphicFrame, let id = Self.rel(a, "id"), case .none? = current?.kind { current?.kind = .chart(relID: id) }
        case "sp", "grpSp", "cxnSp", "contentPart", "AlternateContent":
            if case .none? = current?.kind { current?.kind = .other(name) }
        default: break
        }
    }
    func text(_ s: String) { if field != nil { buffer += s } }
    func end(_ name: String) {
        switch name {
        case "oneCellAnchor", "twoCellAnchor", "absoluteAnchor":
            if var anchor = current {
                if case .other("pic") = anchor.kind { anchor.kind = .other("pic without a blip") }
                if inGraphicFrame, case .none = anchor.kind { anchor.kind = .other("graphicFrame") }
                anchors.append(anchor)
            }
            current = nil; inGraphicFrame = false
        case "from", "to": corner = nil
        case "col", "colOff", "row", "rowOff":
            guard let corner, field == name, let v = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) else { field = nil; return }
            field = nil
            func apply(_ c: inout (column: Int, row: Int, columnOffset: Int, rowOffset: Int)) {
                switch name {
                case "col": c.column = v
                case "colOff": c.columnOffset = v
                case "row": c.row = v
                default: c.rowOffset = v
                }
            }
            if corner == "from" { if current != nil { apply(&current!.from) } } else if current != nil { apply(&current!.to) }
        case "graphicFrame": inGraphicFrame = false
        default: break
        }
    }
}

/// xl/charts/chartN.xml → `Chart`: the first chart group of the plot area names the kind (`barChart` + `barDir`
/// → column / bar, `lineChart`, `pieChart`; anything else keeps its element name as the raw kind), the series
/// carry their name (literal or reference), categories and values as the references they hold, and the title
/// is the chart's own (an axis title is inside the plot area and is not it).
final class ChartPartParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    private static let groups: Set<String> = ["areaChart", "area3DChart", "lineChart", "line3DChart", "stockChart", "radarChart",
                                              "scatterChart", "pieChart", "pie3DChart", "doughnutChart", "barChart", "bar3DChart",
                                              "ofPieChart", "surfaceChart", "surface3DChart", "bubbleChart"]
    private var kind: Chart.Kind?
    private var groupElement: String?
    private var barDir = "col"
    private var inPlotArea = false, inTitle = false, inText = false, inSeries = false
    private var titleText = ""
    private var legend = false
    private var series: [Chart.Series] = []
    private var slot: String?           // tx / cat / val / xVal / yVal
    private var refKind: String?        // strRef / numRef
    private var inF = false, inV = false
    private var buffer = ""
    private var seriesName: String?, seriesNameRef: String?, categories: String?, values: String?

    var chart: Chart? {
        guard let kind else { return nil }
        var c = Chart(kind, title: titleText.isEmpty ? nil : titleText)
        c.legend = legend
        c.series = series
        return c
    }

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "plotArea": inPlotArea = true
        case "title" where !inPlotArea && !inSeries: inTitle = true
        case "t" where inTitle: inText = true
        case "legend" where !inPlotArea: legend = true
        case _ where Self.groups.contains(name) && inPlotArea && kind == nil:
            groupElement = name
        case "barDir" where groupElement != nil: barDir = a["val"] ?? "col"
        case "ser" where inPlotArea:
            inSeries = true; seriesName = nil; seriesNameRef = nil; categories = nil; values = nil
        case "tx", "cat", "val", "xVal", "yVal": if inSeries { slot = name }
        case "strRef", "numRef": if slot != nil { refKind = name }
        case "f" where slot != nil: inF = true; buffer = ""
        case "v" where slot == "tx": inV = true; buffer = ""
        default: break
        }
    }
    func text(_ s: String) {
        if inText { titleText += s } else if inF || inV { buffer += s }
    }
    func end(_ name: String) {
        switch name {
        case "plotArea": inPlotArea = false
        case "title" where inTitle: inTitle = false
        case "t" where inTitle: inText = false
        case _ where name == groupElement:
            switch name {
            case "barChart": kind = barDir == "bar" ? .bar : .column
            case "lineChart": kind = .line
            case "pieChart": kind = .pie
            default: kind = Chart.Kind(rawValue: name)
            }
            groupElement = nil
        case "ser" where inSeries:
            var s = Chart.Series(values: values ?? "", categories: categories, name: seriesName)
            s.nameReference = seriesNameRef
            series.append(s)
            inSeries = false
        case "f" where inF:
            inF = false
            switch slot {
            case "tx": seriesNameRef = buffer
            case "cat", "xVal": categories = buffer
            case "val", "yVal": values = buffer
            default: break
            }
        case "v" where inV: inV = false; if slot == "tx" { seriesName = buffer }
        case "tx", "cat", "val", "xVal", "yVal": if slot == name { slot = nil; refKind = nil }
        default: break
        }
    }
}

enum DrawingReader {
    /// Reads a sheet's drawing into the model. `rels` are the drawing part's own relationships, `read` fetches a
    /// referenced part by path; `sheet` supplies the row and column sizes an EMU extent is measured against.
    static func contents(of drawingData: Data, part: String, rels: [Relationship], sheet: Sheet,
                         read: (String) throws -> Data?) throws -> DrawingContents {
        let parser = DrawingParser()
        try parser.run(drawingData, part: part)
        var out = DrawingContents()
        let dir = (part as NSString).deletingLastPathComponent
        func target(_ id: String) -> String? {
            rels.first { $0.id == id }.map { WorkbookReader.resolvePart($0.target, relativeTo: dir) }
        }
        for anchor in parser.anchors {
            switch anchor.kind {
            case .picture(let relID):
                guard let path = target(relID), let data = try read(path) else { out.unmodelled.append("picture \(relID) without a media part"); continue }
                out.referencedParts.append(path)
                guard var image = try? SheetImage(data: data) else {
                    out.unmodelled.append("picture in a format the model cannot hold (\((path as NSString).pathExtension))"); continue
                }
                image.anchor = imageAnchor(anchor, image: image, sheet: sheet)
                out.images.append(image)
            case .chart(let relID):
                guard let path = target(relID), let data = try read(path) else { out.unmodelled.append("chart \(relID) without a chart part"); continue }
                out.referencedParts.append(path)
                let cp = ChartPartParser()
                guard (try? cp.run(data, part: path)) != nil, var chart = cp.chart else { out.unmodelled.append("chart part \(path) could not be read"); continue }
                chart.anchor = chartRange(anchor, sheet: sheet)
                out.charts.append(chart)
            case .other(let what): out.unmodelled.append(what)
            case .none: out.unmodelled.append("empty anchor")
            }
        }
        return out
    }

    /// The model's anchor for a picture: a one-cell anchor is `.cell` (original size when the extent is the
    /// picture's own pixels, scaled otherwise), a two-cell anchor `.span`, an absolute anchor `.absolute` in points.
    static func imageAnchor(_ a: DrawingAnchor, image: SheetImage, sheet: Sheet) -> SheetImage.Anchor {
        switch a.shape {
        case .oneCell:
            let ref = CellRef(row: a.from.row + 1, column: a.from.column + 1)
            guard let ext = a.ext else { return .cell(ref, sizing: .original) }
            let w = Units.emuToPixels(Double(ext.cx)), h = Units.emuToPixels(Double(ext.cy))
            return .cell(ref, sizing: w == image.pixelWidth && h == image.pixelHeight ? .original : .scaled(width: w, height: h))
        case .twoCell:
            return .span(span(a))
        case .absolute:
            let pos = a.pos ?? (0, 0), ext = a.ext ?? (Units.pixelsToEMU(Double(image.pixelWidth)), Units.pixelsToEMU(Double(image.pixelHeight)))
            return .absolute(x: Double(pos.x) / 12700, y: Double(pos.y) / 12700, width: Double(ext.cx) / 12700, height: Double(ext.cy) / 12700)
        }
    }

    /// The cell range a chart covers: the two-cell anchor's own, or — for a one-cell or absolute anchor — the
    /// cells its extent reaches over from its top-left, measured against the sheet's column widths and row heights.
    static func chartRange(_ a: DrawingAnchor, sheet: Sheet) -> CellRange {
        switch a.shape {
        case .twoCell: return span(a)
        case .oneCell, .absolute:
            var column = a.from.column + 1, row = a.from.row + 1
            if a.shape == .absolute, let pos = a.pos {
                (column, row) = cell(atEMU: (pos.x, pos.y), sheet: sheet)
            }
            let ext = a.ext ?? (0, 0)
            var right = column, bottom = row, x = 0, y = 0
            while x + columnEMU(right, sheet) < ext.cx, right < CellRef.maxColumn { x += columnEMU(right, sheet); right += 1 }
            while y + rowEMU(bottom, sheet) < ext.cy, bottom < CellRef.maxRow { y += rowEMU(bottom, sheet); bottom += 1 }
            return CellRange(from: CellRef(row: row, column: column), to: CellRef(row: bottom, column: right))
        }
    }

    private static func span(_ a: DrawingAnchor) -> CellRange {
        // `to` is exclusive when its offset is 0 (the writer's own form); an offset into the cell means the
        // picture reaches into it
        let toColumn = max(a.to.column + (a.to.columnOffset > 0 ? 1 : 0), a.from.column + 1)
        let toRow = max(a.to.row + (a.to.rowOffset > 0 ? 1 : 0), a.from.row + 1)
        return CellRange(from: CellRef(row: a.from.row + 1, column: a.from.column + 1), to: CellRef(row: toRow, column: toColumn))
    }
    private static func columnEMU(_ column: Int, _ sheet: Sheet) -> Int {
        Units.pixelsToEMU(CellPixels.columnPixels(sheet.columnDimensions[column]?.width ?? CellPixels.defaultColumnWidth))
    }
    private static func rowEMU(_ row: Int, _ sheet: Sheet) -> Int {
        Units.pixelsToEMU(CellPixels.rowPixels(sheet.rowDimensions[row]?.height ?? CellPixels.defaultRowHeight))
    }
    private static func cell(atEMU p: (Int, Int), sheet: Sheet) -> (column: Int, row: Int) {
        var column = 1, x = 0
        while x + columnEMU(column, sheet) <= p.0, column < CellRef.maxColumn { x += columnEMU(column, sheet); column += 1 }
        var row = 1, y = 0
        while y + rowEMU(row, sheet) <= p.1, row < CellRef.maxRow { y += rowEMU(row, sheet); row += 1 }
        return (column, row)
    }
}
