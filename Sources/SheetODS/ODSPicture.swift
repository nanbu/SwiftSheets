import Foundation
import SheetCore

/// A picture placed with `addImage`, on its way into an ODS package (spec Appendix B.43): the part it becomes
/// under `Pictures/`, the cell whose element carries its frame, and the frame's size in the centimetres ODF
/// measures in.
struct ODSPicture {
    let image: SheetImage
    /// `Pictures/image3.png` — the part's path in the package, which the frame's `xlink:href` names.
    let href: String
    /// The document-wide number the part and the frame are named by.
    let number: Int
    /// Stacking order within the sheet.
    let zIndex: Int

    /// The cell whose element carries the frame: the anchor cell, or a span's top-left corner.
    var anchor: CellRef {
        switch image.anchor {
        case .cell(let ref, _): return ref
        case .span(let range): return range.topLeft
        }
    }

    static func fileExtension(_ format: SheetImage.Format) -> String {
        switch format {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        }
    }

    /// 96 pixels to the inch — the assumption every spreadsheet application makes of a picture's pixel size.
    static let centimetresPerPixel = 2.54 / 96

    /// The frame's size in centimetres. A picture at one cell is drawn at its display size (spec Appendix B.32:
    /// the pixel size, the size the caller chose, or the largest that fits the cell as it is now). A picture over
    /// a range is given the range's width and height as this writer describes its columns and rows; the reader
    /// takes the real size from `table:end-cell-address`.
    func size(in sheet: Sheet) -> (width: Double, height: Double) {
        switch image.anchor {
        case .cell(let ref, _):
            let cell = (width: CellPixels.columnPixels(sheet.columnDimensions[ref.col]?.width ?? CellPixels.defaultColumnWidth),
                        height: CellPixels.rowPixels(sheet.rowDimensions[ref.row]?.height ?? CellPixels.defaultRowHeight))
            let shown = image.displaySize(cellSize: cell)
            return (shown.width * Self.centimetresPerPixel, shown.height * Self.centimetresPerPixel)
        case .span(let range):
            var width = 0.0, height = 0.0
            for c in range.minCol...range.maxCol {
                width += (sheet.columnDimensions[c]?.width ?? CellPixels.defaultColumnWidth) * ODSLength.millimetresPerCharacter / 10
            }
            for r in range.minRow...range.maxRow {
                height += (sheet.rowDimensions[r]?.height ?? CellPixels.defaultRowHeight) * 2.54 / 72
            }
            return (width, height)
        }
    }

    /// The frames of the pictures anchored at one cell, in the order they were added: a `draw:frame` sized in
    /// centimetres at the cell's top-left corner, holding a `draw:image` that embeds the part. A picture over a
    /// range also names the cell past the range's far corner as its end, which LibreOffice reads as an anchor that
    /// resizes with its cells.
    static func framesXML(_ pictures: [ODSPicture], in sheet: Sheet) -> String {
        var s = ""
        for p in pictures {
            let size = p.size(in: sheet)
            s += "<draw:frame draw:z-index=\"\(p.zIndex)\" draw:name=\"Image \(p.number)\""
                + " svg:width=\"\(ODSLength.cmValue(size.width))\" svg:height=\"\(ODSLength.cmValue(size.height))\" svg:x=\"0cm\" svg:y=\"0cm\""
            if case .span(let range) = p.image.anchor {
                let end = CellRef(row: range.maxRow + 1, col: range.maxCol + 1)
                s += " table:end-cell-address=\"\(XML.esc(ODSFeatures.address(end, sheet: sheet.name)))\" table:end-x=\"0cm\" table:end-y=\"0cm\""
            }
            s += "><draw:image xlink:href=\"\(XML.esc(p.href))\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\""
                + " draw:mime-type=\"\(p.image.format.contentType)\"/></draw:frame>"
        }
        return s
    }
}
