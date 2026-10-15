import Foundation

/// An exact source drawing position, in English Metric Units (12,700 EMUs per point).
/// It supplements the existing cell/range/canvas anchors without requiring a grid layout or a graphics framework.
public enum DrawingAnchor: Hashable, Sendable {
    /// A cell and a displacement from its top-left corner; offsets are EMUs and may be fractional points.
    public struct Marker: Hashable, Sendable {
        /// Zero-based source indices, including an exclusive end marker just beyond the last cell.
        public let column: Int64
        public let row: Int64
        /// The indexed cell when it lies within the supported grid. End markers may lie outside it.
        public var cell: CellRef? {
            guard column >= 0, column < CellRef.maxColumn, row >= 0, row < CellRef.maxRow else { return nil }
            return CellRef(row: Int(row) + 1, column: Int(column) + 1)
        }
        public let columnOffset: Int64
        public let rowOffset: Int64
        public init(cell: CellRef, columnOffset: Int64 = 0, rowOffset: Int64 = 0) {
            self.column = Int64(cell.column - 1); self.row = Int64(cell.row - 1)
            self.columnOffset = columnOffset; self.rowOffset = rowOffset
        }
        package init(column: Int64, row: Int64, columnOffset: Int64, rowOffset: Int64) {
            self.column = column; self.row = row; self.columnOffset = columnOffset; self.rowOffset = rowOffset
        }
    }
    /// A fixed extent following one cell.
    case oneCell(from: Marker, width: Int64, height: Int64)
    /// Two cell markers. `editAs` is the source positioning behaviour, when explicitly stated.
    case twoCell(from: Marker, to: Marker, editAs: String?)
    /// A fixed position and extent measured from the sheet origin.
    case absolute(x: Int64, y: Int64, width: Int64, height: Int64)
}

/// The source drawing's local coordinate system, before any parent group's transform is applied.
public struct DrawingTransform: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public let x: Int64
        public let y: Int64
        public init(x: Int64, y: Int64) { self.x = x; self.y = y }
    }
    public struct Size: Hashable, Sendable {
        public let width: Int64
        public let height: Int64
        public init(width: Int64, height: Int64) { self.width = width; self.height = height }
    }
    /// Local coordinates and extents in EMUs; group children use the coordinate system declared by their parent.
    public package(set) var offset: Point?
    public package(set) var extent: Size?
    public package(set) var childOffset: Point?
    public package(set) var childExtent: Size?
    /// Clockwise rotation in degrees; nil means the source did not state one.
    public package(set) var rotation: Double?
    public package(set) var isHorizontallyFlipped = false
    public package(set) var isVerticallyFlipped = false
    package init() {}
}

/// Source text formatting for drawing inspection. It does not perform font resolution or text layout.
public struct DrawingTextBody: Hashable, Sendable {
    public struct Run: Hashable, Sendable {
        /// Text, a line break, or a field whose current display text is `text`.
        public struct Kind: RawRepresentable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public static let text = Kind(rawValue: "text")
            public static let lineBreak = Kind(rawValue: "lineBreak")
            public static let field = Kind(rawValue: "field")
        }
        public let kind: Kind
        public let text: String
        /// Explicit run formatting only; absent properties inherit from the source's paragraph/style/theme.
        public let font: Font?
        /// Source typefaces, including theme references such as `+mn-lt`, without resolving installed fonts.
        public let latinTypeface: String?
        public let eastAsianTypeface: String?
        public let complexScriptTypeface: String?
        public let attributes: [String: String]
        public let fieldID: String?
        public let fieldType: String?
        package init(kind: Kind, text: String, font: Font?, latinTypeface: String?, eastAsianTypeface: String?,
                     complexScriptTypeface: String?, attributes: [String: String], fieldID: String?, fieldType: String?) {
            self.kind = kind; self.text = text; self.font = font; self.latinTypeface = latinTypeface
            self.eastAsianTypeface = eastAsianTypeface; self.complexScriptTypeface = complexScriptTypeface
            self.attributes = attributes; self.fieldID = fieldID; self.fieldType = fieldType
        }
    }
    public struct Paragraph: Hashable, Sendable {
        public let runs: [Run]
        /// Source paragraph properties, including alignment, indentation and text direction.
        public let attributes: [String: String]
        public var text: String { runs.map(\.text).joined() }
        package init(runs: [Run], attributes: [String: String]) { self.runs = runs; self.attributes = attributes }
    }
    /// Source body properties: for OOXML these include EMU insets (`lIns`, `rIns`, `tIns`, `bIns`), `vert`, `anchor` and `wrap`.
    public let attributes: [String: String]
    public let paragraphs: [Paragraph]
    public var text: String { paragraphs.map(\.text).joined(separator: "\n") }
    package init(attributes: [String: String], paragraphs: [Paragraph]) { self.attributes = attributes; self.paragraphs = paragraphs }
}

/// Immutable information about a drawing as it was read. This is a source snapshot, not an editing model:
/// changing `sheet.shapes`, pictures, charts or their anchors does not update it. Nil on sheets without a source drawing.
public struct DrawingInfo: Hashable, Sendable {
    /// A selected source property the editable model cannot fully express. XML is inert source data, with
    /// inherited namespace bindings supplied separately (prefix → namespace URI, empty prefix for the default).
    public struct Property: Hashable, Sendable {
        public let name: String
        public let xml: String
        public let namespaces: [String: String]
        package init(name: String, xml: String, namespaces: [String: String]) {
            self.name = name; self.xml = xml; self.namespaces = namespaces
        }
    }
    public struct Object: Hashable, Sendable {
        public struct Kind: RawRepresentable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public static let shape = Kind(rawValue: "shape")
            public static let image = Kind(rawValue: "image")
            public static let chart = Kind(rawValue: "chart")
            public static let group = Kind(rawValue: "group")
            public static let unknown = Kind(rawValue: "unknown")
        }
        public let kind: Kind
        public let sourceElement: String
        public let sourceID: String?
        public let name: String?
        /// Only top-level objects have sheet anchors; group children use their local transform instead.
        public package(set) var anchor: DrawingAnchor?
        public let transform: DrawingTransform?
        /// The source preset name, or `custom` for a custom geometry. It does not claim rendering support.
        public let geometry: String?
        public let textBody: DrawingTextBody?
        /// Children in source order, retaining nested groups without flattening their coordinate systems.
        public let children: [Object]
        public let properties: [Property]
        /// Source features the editable model cannot reproduce when this object has to be rebuilt.
        public let unmodelledProperties: [String]
        package init(kind: Kind, sourceElement: String, sourceID: String?, name: String?, transform: DrawingTransform?,
                     geometry: String?, textBody: DrawingTextBody?, children: [Object], properties: [Property], unmodelledProperties: [String]) {
            self.kind = kind; self.sourceElement = sourceElement; self.sourceID = sourceID; self.name = name
            self.transform = transform; self.geometry = geometry; self.textBody = textBody; self.children = children
            self.properties = properties; self.unmodelledProperties = unmodelledProperties
        }
    }
    public let part: String
    public let objects: [Object]
    package init(part: String, objects: [Object]) { self.part = part; self.objects = objects }
    /// Top-level model objects with source properties that are lost when a drawing is rebuilt.
    package var hasUnmodelledProperties: Bool {
        objects.contains { $0.kind != .group && !$0.unmodelledProperties.isEmpty }
    }
}

extension Sheet {
    /// Conversion writers use the editable model, so source-only details and fractional cell positions need a loss notice.
    package var drawingConversionWarning: ConversionWarning? {
        let positions = images.contains { $0.drawingAnchor?.requiresApproximation == true }
            || shapes.contains { $0.drawingAnchor?.requiresApproximation == true }
            || charts.contains { chart in
                guard let anchor = chart.drawingAnchor else { return false }
                if case .twoCell = anchor { return anchor.requiresApproximation }
                return true // the other writers place an XLSX chart by its covering cell range
            }
        guard positions || drawingInfo?.hasUnmodelledProperties == true else { return nil }
        return ConversionWarning(.degraded, subject: .objects, sheet: name,
                                 context: .init(code: .drawingSimplified, part: drawingInfo?.part, preservation: .partial),
                                 message: "source drawing details (fractional cell positions, transforms, text formatting, geometry or effects) are approximated by the target writer's editable model")
    }
}

extension DrawingAnchor {
    private var hasFractionalExtent: Bool {
        if case .oneCell(_, let width, let height) = self { return width % 9525 != 0 || height % 9525 != 0 }
        return false
    }
    package var requiresApproximation: Bool {
        switch self {
        case .oneCell(let from, _, _): return from.columnOffset != 0 || from.rowOffset != 0 || hasFractionalExtent
        case .twoCell(let from, let to, let editAs):
            return from.columnOffset != 0 || from.rowOffset != 0 || to.columnOffset != 0 || to.rowOffset != 0
                || (editAs != nil && editAs != "twoCell")
        case .absolute: return false
        }
    }
}
