import Foundation

/// A picture placed on a sheet by this library (spec Appendix B.32).
///
/// This is the *adding* side only. Pictures already in a file the reader opened stay preserved as opaque bytes
/// (F3) and do not appear here; `images` holds what `addImage` put in. The format and pixel size are read from
/// the bytes themselves — what the caller believes the data to be plays no part.
public struct SheetImage: Hashable, Sendable {
    /// The three formats OOXML viewers render everywhere. What the leading bytes say, never the file extension.
    public enum Format: String, Sendable {
        case png, jpeg, gif
        /// The `[Content_Types].xml` default for this format's extension.
        public var contentType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            case .gif: "image/gif"
            }
        }
    }

    /// How the picture is sized at its anchor.
    public enum Sizing: Hashable, Sendable {
        /// The image's own pixel size.
        case original
        /// An explicit size in pixels.
        case scaled(width: Int, height: Int)
        /// Shrunk or grown to fit the anchor cell's current size, aspect ratio kept.
        case fitCell
    }

    /// Where the picture sits.
    public enum Anchor: Hashable, Sendable {
        /// Pinned to one cell's top-left corner (`xdr:oneCellAnchor` — the cell may move, the size is the image's).
        case cell(CellRef, sizing: Sizing)
        /// Stretched over a range (`xdr:twoCellAnchor` — both corners follow their cells).
        case span(CellRange)
    }

    public let data: Data
    public let format: Format
    public let pixelWidth: Int
    public let pixelHeight: Int
    public var anchor: Anchor

    /// Reads the format and pixel size from the bytes. Unknown leading bytes throw `unsupportedFeature`; a
    /// recognized header too damaged to say its size throws `malformedPart`.
    public init(data: Data) throws {
        let bytes = [UInt8](data.prefix(32))
        self.data = data
        self.anchor = .cell(CellRef(row: 0, col: 0), sizing: .original)
        if bytes.count >= 8, bytes[0...3] == [0x89, 0x50, 0x4E, 0x47] {
            format = .png
            // IHDR is mandatory and first: width and height are big-endian at offsets 16 and 20
            guard data.count >= 24 else { throw SheetError.malformedPart(path: "image", detail: "PNG too short for IHDR") }
            (pixelWidth, pixelHeight) = (Self.be32(data, 16), Self.be32(data, 20))
        } else if bytes.count >= 10, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            format = .gif
            pixelWidth = Int(data[data.startIndex + 6]) | Int(data[data.startIndex + 7]) << 8
            pixelHeight = Int(data[data.startIndex + 8]) | Int(data[data.startIndex + 9]) << 8
        } else if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            format = .jpeg
            guard let size = Self.jpegSize(data) else { throw SheetError.malformedPart(path: "image", detail: "JPEG has no readable SOF marker") }
            (pixelWidth, pixelHeight) = size
        } else {
            throw SheetError.unsupportedFeature("unrecognized image format (PNG, JPEG and GIF are supported)")
        }
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw SheetError.malformedPart(path: "image", detail: "image declares a zero dimension")
        }
    }

    private static func be32(_ data: Data, _ offset: Int) -> Int {
        let i = data.startIndex + offset
        return Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
    }

    /// Walks the marker chain to the first SOF (C0–CF except the non-frame C4/C8/CC): height then width, big-endian.
    private static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        var i = 2
        while i + 9 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = bytes[i + 1]
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                return (Int(bytes[i + 7]) << 8 | Int(bytes[i + 8]), Int(bytes[i + 5]) << 8 | Int(bytes[i + 6]))
            }
            i += 2 + (Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]))
        }
        return nil
    }

    /// The size the picture is drawn at, in pixels. `cellSize` is the anchor cell's current size, used by `.fitCell`.
    public func displaySize(cellSize: (width: Double, height: Double)? = nil) -> (width: Double, height: Double) {
        guard case .cell(_, let sizing) = anchor else { return (Double(pixelWidth), Double(pixelHeight)) }
        switch sizing {
        case .original: return (Double(pixelWidth), Double(pixelHeight))
        case .scaled(let w, let h): return (Double(w), Double(h))
        case .fitCell:
            guard let cell = cellSize, cell.width > 0, cell.height > 0 else { return (Double(pixelWidth), Double(pixelHeight)) }
            let scale = min(cell.width / Double(pixelWidth), cell.height / Double(pixelHeight))
            return (Double(pixelWidth) * scale, Double(pixelHeight) * scale)
        }
    }
}

/// How `addImage(_:at:sizing:)` should place the picture. Distinct from `SheetImage.Sizing` because one case —
/// `.resizeCellToFit` — is an action on the sheet (resize the cell now), not a property of the stored image.
public enum ImagePlacement: Hashable, Sendable {
    case original
    case scaled(width: Int, height: Int)
    case fitCell
    /// XLKit's signature move: the column and row grow to the image, which then fills them exactly.
    case resizeCellToFit
}

/// The pixel arithmetic of cell sizes (Calibri 11's standard metrics: a column of width w is w·7+5 px, a row of
/// h points is h ÷ 0.75 px). Shared by `.fitCell` and `.resizeCellToFit` — approximations by nature, since the
/// real width depends on the workbook's default font, which viewers themselves only approximate.
public enum CellPixels {
    public static let defaultColumnWidth = 8.43   // characters
    public static let defaultRowHeight = 15.0     // points
    public static func columnPixels(_ widthCharacters: Double) -> Double { (widthCharacters * 7 + 5).rounded() }
    public static func rowPixels(_ heightPoints: Double) -> Double { (heightPoints / 0.75).rounded() }
    public static func columnWidth(forPixels px: Double) -> Double { max((px - 5) / 7, 0) }
    public static func rowHeight(forPixels px: Double) -> Double { px * 0.75 }
}
