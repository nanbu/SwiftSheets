import Foundation

/// A drawn shape on a sheet (spec Appendix B.75): a preset geometry — a rectangle, an arrow, a line — with
/// optional text, or a text box. Placed by `addShape` / `addTextBox`, or read from a file's drawing; a shape read
/// from a file and left untouched is written back as the bytes it arrived in, like a picture or a chart (B.72).
///
/// What the model holds is what both formats can say: the geometry, the text with one font and one alignment,
/// a solid fill, an outline, and the anchor. Gradients, shadows, rotation, effects and per-run text formatting
/// are not modelled — an untouched shape keeps them in its bytes; a rebuilt one loses them, and the writer says so.
public struct Shape: Hashable, Sendable {
    /// The geometry, by its OOXML preset name (`rect`, `ellipse`, `rightArrow`, … — ST_ShapeType). A struct with
    /// static members rather than an enum, so a geometry can be added without breaking a caller's `switch`
    /// (spec Appendix B.69). A shape read from an ODS file may carry a LibreOffice name the preset list does not
    /// know; `isPreset` says whether the XLSX writer can name it, and an unknown one is written as a rectangle
    /// with a warning.
    public struct Geometry: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// A rectangle.
        public static let rectangle = Geometry(rawValue: "rect")
        /// A rectangle with rounded corners.
        public static let roundedRectangle = Geometry(rawValue: "roundRect")
        /// An ellipse — a circle when the anchor is square.
        public static let ellipse = Geometry(rawValue: "ellipse")
        /// A diamond.
        public static let diamond = Geometry(rawValue: "diamond")
        /// An isosceles triangle, point up.
        public static let triangle = Geometry(rawValue: "triangle")
        /// A block arrow pointing right.
        public static let rightArrow = Geometry(rawValue: "rightArrow")
        /// A block arrow pointing left.
        public static let leftArrow = Geometry(rawValue: "leftArrow")
        /// A block arrow pointing up.
        public static let upArrow = Geometry(rawValue: "upArrow")
        /// A block arrow pointing down.
        public static let downArrow = Geometry(rawValue: "downArrow")
        /// A straight line from the anchor's top-left to its bottom-right.
        public static let line = Geometry(rawValue: "line")
        /// A text box: a rectangle whose point is its text — no fill and no outline unless given.
        public static let textBox = Geometry(rawValue: "textBox")
        /// Whether the name is one of OOXML's preset geometries (or the text box), which every writer can draw.
        public var isPreset: Bool { self == .textBox || Geometry.presets.contains(rawValue) }
        public var description: String { rawValue }

        /// ST_ShapeType (ECMA-376 Part 1, §20.1.10.56), the names Excel accepts in `a:prstGeom`.
        package static let presets: Set<String> = [
            "line", "lineInv", "triangle", "rtTriangle", "rect", "diamond", "parallelogram", "trapezoid", "nonIsoscelesTrapezoid",
            "pentagon", "hexagon", "heptagon", "octagon", "decagon", "dodecagon", "star4", "star5", "star6", "star7", "star8",
            "star10", "star12", "star16", "star24", "star32", "roundRect", "round1Rect", "round2SameRect", "round2DiagRect",
            "snipRoundRect", "snip1Rect", "snip2SameRect", "snip2DiagRect", "plaque", "ellipse", "teardrop", "homePlate",
            "chevron", "pieWedge", "pie", "blockArc", "donut", "noSmoking", "rightArrow", "leftArrow", "upArrow", "downArrow",
            "stripedRightArrow", "notchedRightArrow", "bentUpArrow", "leftRightArrow", "upDownArrow", "leftUpArrow",
            "leftRightUpArrow", "quadArrow", "leftArrowCallout", "rightArrowCallout", "upArrowCallout", "downArrowCallout",
            "leftRightArrowCallout", "upDownArrowCallout", "quadArrowCallout", "bentArrow", "uturnArrow", "circularArrow",
            "leftCircularArrow", "leftRightCircularArrow", "curvedRightArrow", "curvedLeftArrow", "curvedUpArrow",
            "curvedDownArrow", "swooshArrow", "cube", "can", "lightningBolt", "heart", "sun", "moon", "smileyFace",
            "irregularSeal1", "irregularSeal2", "foldedCorner", "bevel", "frame", "halfFrame", "corner", "diagStripe", "chord",
            "arc", "leftBracket", "rightBracket", "leftBrace", "rightBrace", "bracketPair", "bracePair", "straightConnector1",
            "bentConnector2", "bentConnector3", "bentConnector4", "bentConnector5", "curvedConnector2", "curvedConnector3",
            "curvedConnector4", "curvedConnector5", "callout1", "callout2", "callout3", "accentCallout1", "accentCallout2",
            "accentCallout3", "borderCallout1", "borderCallout2", "borderCallout3", "accentBorderCallout1",
            "accentBorderCallout2", "accentBorderCallout3", "wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout",
            "cloudCallout", "cloud", "ribbon", "ribbon2", "ellipseRibbon", "ellipseRibbon2", "leftRightRibbon", "verticalScroll",
            "horizontalScroll", "wave", "doubleWave", "plus", "flowChartProcess", "flowChartDecision", "flowChartInputOutput",
            "flowChartPredefinedProcess", "flowChartInternalStorage", "flowChartDocument", "flowChartMultidocument",
            "flowChartTerminator", "flowChartPreparation", "flowChartManualInput", "flowChartManualOperation",
            "flowChartConnector", "flowChartPunchedCard", "flowChartPunchedTape", "flowChartSummingJunction", "flowChartOr",
            "flowChartCollate", "flowChartSort", "flowChartExtract", "flowChartMerge", "flowChartOfflineStorage",
            "flowChartOnlineStorage", "flowChartMagneticTape", "flowChartMagneticDisk", "flowChartMagneticDrum",
            "flowChartDisplay", "flowChartDelay", "flowChartAlternateProcess", "flowChartOffpageConnector", "actionButtonBlank",
            "actionButtonHome", "actionButtonHelp", "actionButtonInformation", "actionButtonForwardNext",
            "actionButtonBackPrevious", "actionButtonEnd", "actionButtonBeginning", "actionButtonReturn",
            "actionButtonDocument", "actionButtonSound", "actionButtonMovie", "gear6", "gear9", "funnel", "mathPlus",
            "mathMinus", "mathMultiply", "mathDivide", "mathEqual", "mathNotEqual", "cornerTabs", "squareTabs", "plaqueTabs",
            "chartX", "chartStar", "chartPlus",
        ]
    }

    /// The shape's outline: a colour and a width in points.
    public struct Outline: Hashable, Sendable {
        /// The line colour.
        public var color: Color
        /// The line width in points.
        public var width: Double
        public init(color: Color, width: Double = 0.75) { self.color = color; self.width = width }
    }

    /// The outline the shape draws.
    public var geometry: Geometry
    /// The text inside the shape; paragraphs are separated by `\n`.
    public var text: String?
    /// One font for all of the text (nil: the application's default).
    public var font: Font?
    /// How the text's paragraphs are aligned (nil: the application's default — left, or centred in a shape).
    public var textAlignment: Alignment.Horizontal?
    /// A solid fill; nil is no fill.
    public var fill: Color?
    /// The outline; nil is no outline.
    public var outline: Outline?
    /// The name the file gives the shape (`Rectangle 3`, `TextBox 1`); nil for one made here.
    public var name: String?
    /// Where the shape sits — the same anchors a picture has. A shape made here covers cell A1 until
    /// `addShape(_:over:)` or `addTextBox(_:over:font:)` places it.
    public var anchor: SheetImage.Anchor = .span(CellRange(minRow: 1, minColumn: 1, maxRow: 1, maxColumn: 1))

    /// A shape of `geometry` with optional text, no fill and no outline, covering cell A1 until it is placed.
    public init(_ geometry: Geometry, text: String? = nil) {
        self.geometry = geometry; self.text = text
    }
}

extension Sheet {
    /// Places a shape over a range (spec Appendix B.75). It rides the same drawing part as pictures and charts.
    public mutating func addShape(_ shape: Shape, over range: CellRange) {
        var s = shape
        s.anchor = .span(range)
        shapes.append(s)
    }
    /// A1 form of `addShape(_:over:)`. An unparseable range is a programmer error, as with subscripts.
    public mutating func addShape(_ shape: Shape, over a1: String) { addShape(shape, over: CellRange(a1)!) }
    /// Places a text box over a range: a shape whose geometry is `.textBox`, with no fill and no outline.
    public mutating func addTextBox(_ text: String, over range: CellRange, font: Font? = nil) {
        var s = Shape(.textBox, text: text)
        s.font = font
        addShape(s, over: range)
    }
    /// A1 form of `addTextBox(_:over:font:)`.
    public mutating func addTextBox(_ text: String, over a1: String, font: Font? = nil) { addTextBox(text, over: CellRange(a1)!, font: font) }
}
