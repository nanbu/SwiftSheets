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
        func at(col: Int, row: Int) -> String {
            "<xdr:col>\(col)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(row)</xdr:row><xdr:rowOff>0</xdr:rowOff>"
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
            return "<xdr:oneCellAnchor \(ns)><xdr:from>\(at(col: ref.col, row: ref.row))</xdr:from>"
                + "<xdr:ext cx=\"\(cx)\" cy=\"\(cy)\"/>" + pic + "<xdr:clientData/></xdr:oneCellAnchor>"
        case .span(let range):
            return "<xdr:twoCellAnchor \(ns)><xdr:from>\(at(col: range.minCol, row: range.minRow))</xdr:from>"
                + "<xdr:to>\(at(col: range.maxCol + 1, row: range.maxRow + 1))</xdr:to>"
                + pic + "<xdr:clientData/></xdr:twoCellAnchor>"
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
        let width = sheet.columnDimensions[ref.col]?.width ?? CellPixels.defaultColumnWidth
        let height = sheet.rowDimensions[ref.row]?.height ?? CellPixels.defaultRowHeight
        return (CellPixels.columnPixels(width), CellPixels.rowPixels(height))
    }
}
