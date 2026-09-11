import Foundation
import SheetCore

/// The pictures, shapes and text boxes standing on a Numbers sheet's canvas (spec Appendix B.83).
///
/// Everything here copies the archives Numbers 15.3.1 wrote for `canvas-15.numbers` — a picture, a text item and a
/// shape made over AppleScript. An image is a `TSD.ImageArchive` pointing at a data record (`TSP.DataInfo` in the
/// package metadata, the bytes under `Data/`); a shape and a text box are both `TSWP.ShapeInfoArchive` (not the
/// plain `TSD.ShapeArchive`), a four-corner bezier path with a text storage of its own. Numbers keeps every object
/// at a point on the canvas, so an anchor is read as `.absolute` and a cell anchor is written by summing the first
/// table's rows and columns.
enum NumbersCanvas {
    /// A geometry the reader hands back for a path that is not a four-corner rectangle. Not a preset name, so
    /// the XLSX and ODS writers draw it as a rectangle and say so.
    static let unknownPath = Shape.Geometry(rawValue: "numbers-path")

    // MARK: - Data records (the bytes of a picture)

    /// Adds the bytes of a picture to the package: a `Data/` entry and its `TSP.DataInfo`. Data identifiers are
    /// their own sequence, separate from object identifiers (the template's are 7, 8 and 15; Numbers gave the
    /// next picture 16), and the digest is the SHA-1 of the bytes. Returns the data identifier.
    static func addData(_ image: SheetImage, name: String, to doc: NumbersDocument) -> Int {
        var records = doc.object(NumbersDocument.packageID)?.messages("datas") ?? []
        let id = (records.compactMap { $0.int("identifier") }.max() ?? 0) + 1
        let fileName = "\(name)-\(id).\(image.format.rawValue)"
        var info = ProtoMessage(typeName: "TSP.DataInfo")
        info.set("identifier", int: id)
        info.set("digest", bytes: SHA1.hash(image.data))
        info.set("preferred_file_name", string: "\(name).\(image.format.rawValue)")
        info.set("file_name", string: fileName)
        var attributes = ProtoMessage(typeName: "TSP.DataAttributes")
        var imageAttributes = ProtoMessage(typeName: "TSD.ImageDataAttributes")
        imageAttributes.set("pixel_size", message: size(Double(image.pixelWidth), Double(image.pixelHeight)))
        imageAttributes.set("should_be_interpreted_as_generic_if_untagged", bool: false)
        attributes.set("TSD.ImageDataAttributes.image_data_attributes", message: imageAttributes)
        info.set("attributes", message: attributes)
        info.set("materialized_length", int: image.data.count)
        records.append(info)
        doc.update(NumbersDocument.packageID) { $0.set("datas", messages: records) }
        doc.setBlob("Data/" + fileName, image.data)
        return id
    }

    /// The bytes a data reference names, by way of the package's data records.
    static func data(_ id: Int, in doc: any NumbersObjectStore) -> (bytes: Data, name: String)? {
        guard let record = doc.object(NumbersDocument.packageID)?.messages("datas").first(where: { $0.int("identifier") == id }) else { return nil }
        let name = record.string("preferred_file_name") ?? ""
        guard let file = record.string("file_name"), !file.isEmpty, let bytes = doc.blob("Data/" + file) else { return nil }
        return (bytes, name)
    }

    // MARK: - Archives

    /// A rectangle in canvas points.
    struct Frame { var x: Double, y: Double, width: Double, height: Double }

    static func geometry(_ frame: Frame) -> ProtoMessage {
        var g = ProtoMessage(typeName: "TSD.GeometryArchive")
        var p = ProtoMessage(typeName: "TSP.Point"); p.set("x", float: Float(frame.x)); p.set("y", float: Float(frame.y))
        g.set("position", message: p)
        g.set("size", message: size(frame.width, frame.height))
        g.set("flags", int: 3)
        g.set("angle", float: 0)
        return g
    }

    static func size(_ width: Double, _ height: Double) -> ProtoMessage {
        var s = ProtoMessage(typeName: "TSP.Size"); s.set("width", float: Float(width)); s.set("height", float: Float(height))
        return s
    }

    /// The `TSD.DrawableArchive` every canvas object starts from, with the wrap Numbers writes.
    static func drawable(_ frame: Frame, parent sheet: Int) -> ProtoMessage {
        var d = ProtoMessage(typeName: "TSD.DrawableArchive")
        d.set("geometry", message: geometry(frame))
        d.set("parent", reference: sheet)
        var wrap = ProtoMessage(typeName: "TSD.ExteriorTextWrapArchive")
        wrap.set("type", int: 4); wrap.set("direction", int: 2); wrap.set("fit_type", int: 1)
        wrap.set("margin", float: 12); wrap.set("alpha_threshold", float: 0.5); wrap.set("is_html_wrap", bool: false)
        d.set("exterior_text_wrap", message: wrap)
        d.set("locked", bool: false)
        d.set("aspect_ratio_locked", bool: false)
        return d
    }

    /// The `TSD.ImageArchive` for one picture whose bytes are data record `data`.
    static func imageArchive(_ image: SheetImage, frame: Frame, data: Int, style: Int?, parent sheet: Int) -> ProtoMessage {
        var a = ProtoMessage(typeName: "TSD.ImageArchive")
        var d = drawable(frame, parent: sheet)
        d.set("aspect_ratio_locked", bool: true)
        a.set("super", message: d)
        if let style { a.set("style", reference: style) }
        a.set("originalSize", message: size(Double(image.pixelWidth), Double(image.pixelHeight)))
        a.set("flags", int: 0)
        a.set("naturalSize", message: size(Double(image.pixelWidth), Double(image.pixelHeight)))
        var ref = ProtoMessage(typeName: "TSP.DataReference"); ref.set("identifier", int: data)
        a.set("data", message: ref)
        a.set("interpretsUntaggedImageDataAsGeneric", bool: false)
        return a
    }

    // MARK: - Geometries as paths (B.87)

    /// One element of a path in the 100 × 100 unit space Numbers scales by `naturalSize`.
    enum PathElement: Equatable {
        case move(Double, Double), line(Double, Double), curve((Double, Double), (Double, Double), (Double, Double)), close
        static func == (a: PathElement, b: PathElement) -> Bool { a.kind == b.kind && a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } }
        var kind: String {
            switch self { case .move: "moveTo"; case .line: "lineTo"; case .curve: "curveTo"; case .close: "closeSubpath" }
        }
        var points: [(Double, Double)] {
            switch self {
            case .move(let x, let y), .line(let x, let y): [(x, y)]
            case .curve(let a, let b, let c): [a, b, c]
            case .close: []
            }
        }
    }

    /// The bezier control distance for a quarter circle.
    static let kappa = 0.5522847498

    /// The unit path of each geometry the writer draws. Nothing here is measured against Numbers' own presets —
    /// Numbers cannot script an oval or an arrow — but Numbers keeps any bezier path it is given, so every
    /// geometry is spelt out as points; the reader recognises these same paths on the way back.
    static func unitPath(_ geometry: Shape.Geometry) -> [PathElement]? {
        let k = kappa * 50
        func polygon(_ pts: [(Double, Double)]) -> [PathElement] {
            [.move(pts[0].0, pts[0].1)] + pts.dropFirst().map { .line($0.0, $0.1) } + [.close, .move(pts[0].0, pts[0].1)]
        }
        switch geometry {
        case .rectangle, .textBox: return polygon([(0, 0), (100, 0), (100, 100), (0, 100)])
        case .ellipse:
            return [.move(50, 0), .curve((50 + k, 0), (100, 50 - k), (100, 50)), .curve((100, 50 + k), (50 + k, 100), (50, 100)),
                    .curve((50 - k, 100), (0, 50 + k), (0, 50)), .curve((0, 50 - k), (50 - k, 0), (50, 0)), .close, .move(50, 0)]
        case .roundedRectangle:
            let r = 16.0, c = kappa * r
            return [.move(r, 0), .line(100 - r, 0), .curve((100 - r + c, 0), (100, r - c), (100, r)), .line(100, 100 - r),
                    .curve((100, 100 - r + c), (100 - r + c, 100), (100 - r, 100)), .line(r, 100), .curve((r - c, 100), (0, 100 - r + c), (0, 100 - r)),
                    .line(0, r), .curve((0, r - c), (r - c, 0), (r, 0)), .close, .move(r, 0)]
        case .diamond: return polygon([(50, 0), (100, 50), (50, 100), (0, 50)])
        case .triangle: return polygon([(50, 0), (100, 100), (0, 100)])
        case .rightArrow: return polygon([(0, 25), (60, 25), (60, 0), (100, 50), (60, 100), (60, 75), (0, 75)])
        case .leftArrow: return polygon([(100, 25), (40, 25), (40, 0), (0, 50), (40, 100), (40, 75), (100, 75)])
        case .upArrow: return polygon([(25, 100), (25, 40), (0, 40), (50, 0), (100, 40), (75, 40), (75, 100)])
        case .downArrow: return polygon([(25, 0), (25, 60), (0, 60), (50, 100), (100, 60), (75, 60), (75, 0)])
        case .line: return [.move(0, 0), .line(100, 100)]
        default: return nil
        }
    }

    /// The geometries the writer draws as their own path; the rest are rectangles, and said so.
    static func isDrawn(_ geometry: Shape.Geometry) -> Bool { unitPath(geometry) != nil }

    static let drawnGeometries: [Shape.Geometry] = [.rectangle, .ellipse, .roundedRectangle, .diamond, .triangle, .rightArrow, .leftArrow, .upArrow, .downArrow, .line]

    /// A `TSD.PathSourceArchive` carrying the unit path of `geometry` (a rectangle for one not drawn) at `size`.
    static func pathSource(_ geometry: Shape.Geometry, width: Double, height: Double) -> ProtoMessage {
        var source = ProtoMessage(typeName: "TSD.PathSourceArchive")
        source.set("horizontalFlip", bool: false); source.set("verticalFlip", bool: false)
        var bezier = ProtoMessage(typeName: "TSD.BezierPathSourceArchive")
        bezier.set("naturalSize", message: size(width, height))
        var path = ProtoMessage(typeName: "TSP.Path")
        path.set("elements", messages: (unitPath(geometry) ?? unitPath(.rectangle)!).map { element in
            var e = ProtoMessage(typeName: "TSP.Path.Element")
            e.set("type", int: NumbersSchema.shared.enumValue("TSP.Path.ElementType", element.kind) ?? 1)
            e.set("points", messages: element.points.map { var p = ProtoMessage(typeName: "TSP.Point"); p.set("x", float: Float($0.0)); p.set("y", float: Float($0.1)); return p })
            return e
        })
        bezier.set("path", message: path)
        source.set("bezier_path_source", message: bezier)
        return source
    }

    /// The same, for the rectangle (kept by name for the text box).
    static func rectanglePath(width: Double, height: Double) -> ProtoMessage { pathSource(.rectangle, width: width, height: height) }

    /// The elements of a path source as read, in the unit space (a path whose natural size is not 100 × 100 is
    /// scaled into it). Nil for a source that is not a bezier path.
    static func elements(of source: ProtoMessage) -> [PathElement]? {
        guard let bezier = source.message("bezier_path_source"), let path = bezier.message("path") else { return nil }
        let names = NumbersSchema.shared.enums["TSP.Path.ElementType"] ?? [:]
        let byValue = Dictionary(names.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let natural = bezier.message("naturalSize")
        let sx = natural.flatMap { $0.float("width") }.map { $0 > 0 ? 100 / Double($0) : 1 } ?? 1
        let sy = natural.flatMap { $0.float("height") }.map { $0 > 0 ? 100 / Double($0) : 1 } ?? 1
        // Numbers writes rectangle paths in a 100-unit space regardless of natural size; detect that case
        let raw = path.messages("elements").map { e -> (String, [(Double, Double)]) in
            (byValue[e.int("type") ?? -1] ?? "?", e.messages("points").map { (Double($0.float("x") ?? 0), Double($0.float("y") ?? 0)) })
        }
        let maxCoordinate = raw.flatMap { $0.1 }.map { Swift.max($0.0, $0.1) }.max() ?? 0
        let unitAlready = abs(maxCoordinate - 100) < 0.5
        var out: [PathElement] = []
        for (kind, pts) in raw {
            let p = pts.map { unitAlready ? $0 : ($0.0 * sx, $0.1 * sy) }
            switch kind {
            case "moveTo" where p.count == 1: out.append(.move(p[0].0, p[0].1))
            case "lineTo" where p.count == 1: out.append(.line(p[0].0, p[0].1))
            case "curveTo" where p.count == 3: out.append(.curve(p[0], p[1], p[2]))
            case "closeSubpath": out.append(.close)
            default: return nil
            }
        }
        return out
    }

    /// The geometry a read path draws, when it is one of ours (within half a unit); `unknownPath` otherwise.
    static func geometry(of source: ProtoMessage) -> Shape.Geometry {
        guard let read = elements(of: source) else { return unknownPath }
        func same(_ a: [PathElement], _ b: [PathElement]) -> Bool {
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) {
                guard x.kind == y.kind, x.points.count == y.points.count else { return false }
                for (p, q) in zip(x.points, y.points) where abs(p.0 - q.0) > 0.5 || abs(p.1 - q.1) > 0.5 { return false }
            }
            return true
        }
        // a trailing moveTo back to the start is Numbers' habit; compare with and without it
        let trimmed = read.last.map { if case .move = $0, read.count > 1, read[read.count - 2] == .close { return Array(read.dropLast()) } else { return read } } ?? read
        for g in drawnGeometries {
            guard let ours = unitPath(g) else { continue }
            if same(read, ours) || same(trimmed, ours) || same(trimmed, Array(ours.dropLast())) { return g }
        }
        return unknownPath
    }

    /// Whether a path source is the four-corner rectangle (any size).
    static func isRectangle(_ source: ProtoMessage) -> Bool { geometry(of: source) == .rectangle }

    /// The `TSWP.ShapeInfoArchive` for a shape or a text box whose text lives in `storage`.
    static func shapeArchive(_ shape: Shape, frame: Frame, style: Int?, storage: Int?, parent sheet: Int) -> ProtoMessage {
        var info = ProtoMessage(typeName: "TSWP.ShapeInfoArchive")
        var shapeArchive = ProtoMessage(typeName: "TSD.ShapeArchive")
        shapeArchive.set("super", message: drawable(frame, parent: sheet))
        if let style { shapeArchive.set("style", reference: style) }
        shapeArchive.set("pathsource", message: pathSource(shape.geometry, width: frame.width, height: frame.height))
        shapeArchive.set("strokePatternOffsetDistance", float: 0)
        info.set("super", message: shapeArchive)
        if let storage {
            info.set("deprecated_storage", reference: storage)
            info.set("owned_storage", reference: storage)
        }
        info.set("is_text_box", bool: shape.geometry == .textBox)
        return info
    }

    /// The text storage of a shape: the template's paragraph style for that kind of shape, one run in `font`.
    static func storage(text: String, stylesheet: Int?, paragraphStyle: Int?, listStyle: Int?, run: Int?) -> ProtoMessage {
        var storage = NumbersRichText.storage(text: text, stylesheet: stylesheet, paragraphStyle: paragraphStyle, listStyle: listStyle,
                                              runs: run.map { [(0, $0)] } ?? [], fields: [], kind: "BODY")
        var bidi = ProtoMessage(typeName: "TSWP.ParaDataAttributeTable")
        var entry = ProtoMessage(typeName: "TSWP.ParaDataAttributeTable.ParaDataAttribute")
        entry.set("character_index", int: 0); entry.set("first", int: 0); entry.set("second", int: 0)
        bidi.set("entries", messages: [entry])
        storage.set("table_para_bidi", message: bidi)
        // Numbers aborts while saving a shape whose storage has no drop-cap table (measured: SIGABRT in TSText)
        var dropCap = ProtoMessage(typeName: "TSWP.ObjectAttributeTable")
        var none = ProtoMessage(typeName: "TSWP.ObjectAttributeTable.ObjectAttribute")
        none.set("character_index", int: 0)
        dropCap.set("entries", messages: [none])
        storage.set("table_drop_cap_style", message: dropCap)
        return storage
    }

    // MARK: - Styles

    /// One of the template's own drawable styles by the identifier Numbers gives it (`image-0-imageStyle`,
    /// `shape-0-shapestyle`, `textbox-0-shapestyle`).
    static func templateStyle(_ identifier: String, ofType type: String, in doc: NumbersDocument) -> Int? {
        doc.identifiers(ofType: type).first { id in
            let sup = doc.object(id)?.message("super")
            let name = sup?.string("style_identifier") ?? sup?.message("super")?.string("style_identifier")
            return name == identifier
        }
    }

    /// A copy of a template shape style with the fill and the outline the model asks for, added to the stylesheet.
    /// Nil when the shape asks for neither (the template style serves as it is).
    static func shapeStyle(for shape: Shape, from template: Int, in doc: NumbersDocument) throws -> Int? {
        guard shape.fill != nil || shape.outline != nil, var style = doc.object(template) else { return nil }
        var outer = style.message("super") ?? ProtoMessage(typeName: "TSD.ShapeStyleArchive")
        var properties = outer.message("shape_properties") ?? ProtoMessage(typeName: "TSD.ShapeStylePropertiesArchive")
        if let fill = shape.fill {
            var f = ProtoMessage(typeName: "TSD.FillArchive")
            if case .rgb(let hex) = fill, let colour = NumbersStyleWriter.color(hex) { f.set("color", message: colour) }
            properties.set("fill", message: f)
        }
        if let outline = shape.outline {
            var stroke = properties.message("stroke") ?? ProtoMessage(typeName: "TSD.StrokeArchive")
            if case .rgb(let hex) = outline.color, let colour = NumbersStyleWriter.color(hex) { stroke.set("color", message: colour) }
            stroke.set("width", float: Float(outline.width))
            var pattern = ProtoMessage(typeName: "TSD.StrokePatternArchive")
            pattern.set("type", int: NumbersSchema.shared.enumValue("TSD.StrokePatternArchive.StrokePatternType", "TSDSolidPattern") ?? 1)
            pattern.set("phase", float: 0); pattern.set("count", int: 0)
            stroke.set("pattern", message: pattern)
            properties.set("stroke", message: stroke)
        }
        outer.set("shape_properties", message: properties)
        var base = outer.message("super") ?? ProtoMessage(typeName: "TSS.StyleArchive")
        base.set("style_identifier", string: "")   // a variation, not a named style of the sheet's list
        base.set("parent", reference: template)
        base.set("is_variation", bool: true)
        outer.set("super", message: base)
        style.set("super", message: outer)
        return try doc.add(style, file: NumbersStyleWriter.stylesheetFile)
    }

    /// The paragraph style a template shape style names for its text.
    static func paragraphStyle(ofShapeStyle id: Int, in doc: NumbersDocument) -> Int? {
        doc.object(id)?.message("shape_properties")?.reference("paragraph_style")
    }

    // MARK: - Reading

    /// The fill and the outline a shape style says.
    static func fillAndOutline(ofStyle id: Int, in doc: any NumbersObjectStore) -> (fill: Color?, outline: Shape.Outline?) {
        guard let properties = doc.object(id)?.message("super")?.message("shape_properties") else { return (nil, nil) }
        let fill = properties.message("fill")?.message("color").flatMap(NumbersStyleResolver.color)
        var outline: Shape.Outline?
        if let stroke = properties.message("stroke"), let width = stroke.float("width"), width > 0,
           stroke.message("pattern")?.int("type") != (NumbersSchema.shared.enumValue("TSD.StrokePatternArchive.StrokePatternType", "TSDEmptyPattern") ?? 2),
           let colour = stroke.message("color").flatMap(NumbersStyleResolver.color) {
            outline = Shape.Outline(color: colour, width: Double(width))
        }
        return (fill, outline)
    }

    /// The frame of a drawable, in canvas points.
    static func frame(of drawable: ProtoMessage) -> Frame? {
        guard let g = drawable.message("geometry"), let p = g.message("position"), let s = g.message("size") else { return nil }
        return Frame(x: Double(p.float("x") ?? 0), y: Double(p.float("y") ?? 0), width: Double(s.float("width") ?? 0), height: Double(s.float("height") ?? 0))
    }

    // MARK: - Anchors

    /// The cell-anchored placements, turned into canvas points against the first table: its origin, and its
    /// rows and columns summed (the defaults are Numbers' own, 20 pt and 98 pt; a width is characters × 5.7 pt).
    struct TableGrid {
        var origin: (x: Double, y: Double)
        var table: Table
        var defaultRowHeight: Double
        var defaultColumnWidth: Double

        func rowHeight(_ r: Int) -> Double { table.rowDimensions[r]?.height ?? defaultRowHeight }
        func columnWidth(_ c: Int) -> Double { table.columnDimensions[c]?.width.map { $0 * NumbersReader.pointsPerCharacter } ?? defaultColumnWidth }
        func top(ofRow r: Int) -> Double { origin.y + (r > 1 ? (1..<r).reduce(0.0) { $0 + rowHeight($1) } : 0) }
        func left(ofColumn c: Int) -> Double { origin.x + (c > 1 ? (1..<c).reduce(0.0) { $0 + columnWidth($1) } : 0) }

        func frame(_ anchor: SheetImage.Anchor, pixelWidth: Int, pixelHeight: Int) -> Frame {
            switch anchor {
            case .absolute(let f): return Frame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
            case .span(let range):
                let x = left(ofColumn: range.minColumn), y = top(ofRow: range.minRow)
                return Frame(x: x, y: y, width: left(ofColumn: range.maxColumn + 1) - x, height: top(ofRow: range.maxRow + 1) - y)
            case .cell(let ref, let sizing):
                let x = left(ofColumn: ref.column), y = top(ofRow: ref.row)
                switch sizing {
                case .original: return Frame(x: x, y: y, width: Double(pixelWidth), height: Double(pixelHeight))
                case .scaled(let w, let h): return Frame(x: x, y: y, width: Double(w), height: Double(h))
                case .fitCell: return Frame(x: x, y: y, width: columnWidth(ref.column), height: rowHeight(ref.row))
                }
            }
        }
    }
}
