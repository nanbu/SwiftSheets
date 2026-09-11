import Foundation
import SheetCore

/// The drawing part a sheet's pictures ride in (spec Appendix B.32).
///
/// A worksheet may point at exactly one drawing, so there are two paths: a sheet with no drawing gets a freshly
/// generated part, and a sheet whose source file already carries one (a chart, older pictures) gets the new
/// anchors spliced into the preserved bytes — everything already there stays byte for byte. The spliced anchors
/// declare their namespaces on themselves, so whatever prefixes the source document chose cannot break them.
enum DrawingParts {
    static let contentType = "application/vnd.openxmlformats-officedocument.drawing+xml"
    /// Relationship type suffixes, against `XMLWriter.nsRel`.
    static let relationshipType = "/drawing"
    static let imageRelationshipType = "/image"

    static let nsSpreadsheetDrawing = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    static let nsDrawingMain = "http://schemas.openxmlformats.org/drawingml/2006/main"

    /// One anchor element, self-contained: namespace declarations ride on the element itself.
    /// `shapeID` must be unique inside the drawing part; `relID` is the image relationship in the part's rels.
    static func anchorXML(_ image: SheetImage, shapeID: Int, relID: String,
                          cellSize: (width: Double, height: Double)) -> String {
        let ns = "xmlns:xdr=\"\(nsSpreadsheetDrawing)\" xmlns:a=\"\(nsDrawingMain)\""
        func at(column: Int, row: Int) -> String {
            // the drawing's anchors count from 0; `to` is exclusive, so a range's maxColumn + 1 lands on the right edge
            "<xdr:col>\(column - 1)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(row - 1)</xdr:row><xdr:rowOff>0</xdr:rowOff>"
        }
        let pic = """
            <xdr:pic><xdr:nvPicPr><xdr:cNvPr id="\(shapeID)" name="Picture \(shapeID)"/>\
            <xdr:cNvPicPr><a:picLocks noChangeAspect="1"/></xdr:cNvPicPr></xdr:nvPicPr>\
            <xdr:blipFill><a:blip xmlns:r="\(XMLWriter.nsRel)" r:embed="\(relID)"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>\
            <xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic>
            """
        switch image.anchor {
        case .cell(let ref, _):
            let size = image.displaySize(cellSize: cellSize)
            let cx = Units.pixelsToEMU(size.width), cy = Units.pixelsToEMU(size.height)
            return "<xdr:oneCellAnchor \(ns)><xdr:from>\(at(column: ref.column, row: ref.row))</xdr:from>"
                + "<xdr:ext cx=\"\(cx)\" cy=\"\(cy)\"/>" + pic + "<xdr:clientData/></xdr:oneCellAnchor>"
        case .span(let range):
            return "<xdr:twoCellAnchor \(ns)><xdr:from>\(at(column: range.minColumn, row: range.minRow))</xdr:from>"
                + "<xdr:to>\(at(column: range.maxColumn + 1, row: range.maxRow + 1))</xdr:to>"
                + pic + "<xdr:clientData/></xdr:twoCellAnchor>"
        case .absolute(let frame):
            let (x, y, w, h) = (frame.origin.x, frame.origin.y, frame.width, frame.height)
            func emu(_ pt: Double) -> Int { Int((pt * 12700).rounded()) }
            return "<xdr:absoluteAnchor \(ns)><xdr:pos x=\"\(emu(x))\" y=\"\(emu(y))\"/><xdr:ext cx=\"\(emu(w))\" cy=\"\(emu(h))\"/>"
                + pic + "<xdr:clientData/></xdr:absoluteAnchor>"
        }
    }

    /// One anchor holding a shape or a text box (B.75): `xdr:sp` with the preset geometry, a solid fill or none,
    /// a line or none, and the text as paragraphs of one run each. `rgb` resolves a colour to `RRGGBB` (theme and
    /// indexed colours through the workbook's theme); a geometry the preset list does not know is written as a
    /// rectangle, which the caller reports.
    static func shapeAnchorXML(_ shape: Shape, shapeID: Int, sheet: Sheet, rgb: (Color) -> String?) -> String {
        let ns = "xmlns:xdr=\"\(nsSpreadsheetDrawing)\" xmlns:a=\"\(nsDrawingMain)\""
        func at(column: Int, row: Int) -> String {
            "<xdr:col>\(column - 1)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(row - 1)</xdr:row><xdr:rowOff>0</xdr:rowOff>"
        }
        func emu(_ pt: Double) -> Int { Int((pt * 12700).rounded()) }
        func solid(_ c: Color) -> String { "<a:solidFill><a:srgbClr val=\"\(String((rgb(c) ?? "000000").suffix(6)))\"/></a:solidFill>" }
        let isTextBox = shape.geometry == .textBox
        let prst = isTextBox ? "rect" : (shape.geometry.isPreset ? shape.geometry.rawValue : "rect")
        // the size, for the transform: the anchor's own for a one-cell or absolute anchor, the range's for a span
        let size: (cx: Int, cy: Int)
        switch shape.anchor {
        case .cell(let ref, let sizing):
            let cell = cellSize(of: sheet, at: .cell(ref, sizing: sizing))
            switch sizing {
            case .scaled(let w, let h): size = (Units.pixelsToEMU(Double(w)), Units.pixelsToEMU(Double(h)))
            default: size = (Units.pixelsToEMU(cell.width), Units.pixelsToEMU(cell.height))
            }
        case .span(let range):
            var w = 0.0, h = 0.0
            for c in range.minColumn...range.maxColumn { w += CellPixels.columnPixels(sheet.columnDimensions[c]?.width ?? CellPixels.defaultColumnWidth) }
            for r in range.minRow...range.maxRow { h += CellPixels.rowPixels(sheet.rowDimensions[r]?.height ?? CellPixels.defaultRowHeight) }
            size = (Units.pixelsToEMU(w), Units.pixelsToEMU(h))
        case .absolute(let frame): size = (emu(frame.width), emu(frame.height))
        }
        var sp = "<xdr:sp macro=\"\" textlink=\"\"><xdr:nvSpPr><xdr:cNvPr id=\"\(shapeID)\" name=\"\(XML.esc(shape.name ?? (isTextBox ? "TextBox \(shapeID)" : "Shape \(shapeID)")))\"/>"
        sp += isTextBox ? "<xdr:cNvSpPr txBox=\"1\"/>" : "<xdr:cNvSpPr/>"
        sp += "</xdr:nvSpPr><xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(size.cx)\" cy=\"\(size.cy)\"/></a:xfrm>"
        sp += "<a:prstGeom prst=\"\(prst)\"><a:avLst/></a:prstGeom>"
        sp += shape.fill.map(solid) ?? "<a:noFill/>"
        if let o = shape.outline { sp += "<a:ln w=\"\(emu(o.width))\">\(solid(o.color))</a:ln>" } else { sp += "<a:ln><a:noFill/></a:ln>" }
        sp += "</xdr:spPr>"
        if let text = shape.text {
            sp += "<xdr:txBody><a:bodyPr wrap=\"square\" rtlCol=\"0\" anchor=\"t\"/><a:lstStyle/>"
            var pPr = ""
            if let a = shape.textAlignment {
                let algn: String? = switch a {
                case .left: "l"
                case .center, .centerContinuous: "ctr"
                case .right: "r"
                case .justify: "just"
                case .distributed: "dist"
                default: nil
                }
                if let algn { pPr = "<a:pPr algn=\"\(algn)\"/>" }
            }
            var rPr = "<a:rPr lang=\"en-US\""
            var rPrBody = ""
            if let f = shape.font {
                if let sz = f.size { rPr += " sz=\"\(Int((sz * 100).rounded()))\"" }
                if f.bold { rPr += " b=\"1\"" }
                if f.italic { rPr += " i=\"1\"" }
                if let u = f.underline { rPr += " u=\"\(u == .double ? "dbl" : "sng")\"" }
                if let c = f.color { rPrBody += solid(c) }
                if let n = f.name { rPrBody += "<a:latin typeface=\"\(XML.esc(n))\"/>" }
            }
            rPr += ">" + rPrBody + "</a:rPr>"
            for paragraph in text.components(separatedBy: "\n") {
                sp += "<a:p>" + pPr
                if !paragraph.isEmpty { sp += "<a:r>" + rPr + "<a:t>\(XML.esc(paragraph))</a:t></a:r>" }
                sp += "</a:p>"
            }
            sp += "</xdr:txBody>"
        }
        sp += "</xdr:sp>"
        switch shape.anchor {
        case .cell(let ref, _):
            return "<xdr:oneCellAnchor \(ns)><xdr:from>\(at(column: ref.column, row: ref.row))</xdr:from>"
                + "<xdr:ext cx=\"\(size.cx)\" cy=\"\(size.cy)\"/>" + sp + "<xdr:clientData/></xdr:oneCellAnchor>"
        case .span(let range):
            return "<xdr:twoCellAnchor \(ns)><xdr:from>\(at(column: range.minColumn, row: range.minRow))</xdr:from>"
                + "<xdr:to>\(at(column: range.maxColumn + 1, row: range.maxRow + 1))</xdr:to>" + sp + "<xdr:clientData/></xdr:twoCellAnchor>"
        case .absolute(let frame):
            let (x, y) = (frame.origin.x, frame.origin.y)
            return "<xdr:absoluteAnchor \(ns)><xdr:pos x=\"\(emu(x))\" y=\"\(emu(y))\"/><xdr:ext cx=\"\(size.cx)\" cy=\"\(size.cy)\"/>"
                + sp + "<xdr:clientData/></xdr:absoluteAnchor>"
        }
    }

    /// A complete, freshly generated drawing part.
    static func drawingXML(anchors: [String]) -> String {
        "<xdr:wsDr xmlns:xdr=\"\(nsSpreadsheetDrawing)\" xmlns:a=\"\(nsDrawingMain)\">" + anchors.joined() + "</xdr:wsDr>"
    }

    /// Splices anchors into an existing drawing part, just before the root's closing tag — whatever prefix the
    /// source chose for the spreadsheetDrawing namespace. Nil when the bytes hold no recognizable close.
    static func appendingAnchors(_ anchors: [String], to bytes: Data) -> Data? {
        guard let xml = String(data: bytes, encoding: .utf8),
              let close = xml.range(of: "</[A-Za-z0-9_]*:?wsDr[ \t\r\n]*>", options: [.regularExpression, .backwards])
        else { return nil }
        return Data((xml[..<close.lowerBound] + anchors.joined() + xml[close.lowerBound...]).utf8)
    }

    /// Adds relationships (image, chart, …) to a drawing's rels part — existing ids stay, new ones are numbered
    /// after the highest in use. `bytes` nil means the drawing had no rels part yet. Each entry is a relationship
    /// type suffix and a target. Returns the new bytes and the fresh ids, in entry order.
    static func appendingRelationships(entries: [(type: String, target: String)], to bytes: Data?) -> (data: Data, ids: [String])? {
        var xml = bytes.flatMap { String(data: $0, encoding: .utf8) }
            ?? XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\"></Relationships>"
        guard let close = xml.range(of: "</Relationships>", options: .backwards) else { return nil }
        var next = 1
        for m in xml.matches(of: /Id="rId([0-9]+)"/) { next = max(next, (Int(m.1) ?? 0) + 1) }
        var ids: [String] = [], inserted = ""
        for entry in entries {
            let id = "rId\(next)"; next += 1; ids.append(id)
            inserted += "<Relationship Id=\"\(id)\" Type=\"\(XMLWriter.nsRel)\(entry.type)\" Target=\"\(XML.esc(entry.target))\"/>"
        }
        xml.replaceSubrange(close.lowerBound..<close.lowerBound, with: inserted)
        return (Data(xml.utf8), ids)
    }

    /// The anchor cell's current pixel size, for `.fitCell`.
    static func cellSize(of sheet: Sheet, at anchor: SheetImage.Anchor) -> (width: Double, height: Double) {
        guard case .cell(let ref, _) = anchor else { return (0, 0) }
        let width = sheet.columnDimensions[ref.column]?.width ?? CellPixels.defaultColumnWidth
        let height = sheet.rowDimensions[ref.row]?.height ?? CellPixels.defaultRowHeight
        return (CellPixels.columnPixels(width), CellPixels.rowPixels(height))
    }
}
