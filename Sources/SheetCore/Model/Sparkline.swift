import Foundation

/// A group of sparklines — the tiny in-cell charts Excel draws from a row or column of numbers (spec Appendix
/// B.79). One group shares a kind, its colours and its options; each sparkline in it draws one range into one
/// cell. OOXML keeps them in the worksheet's `x14:sparklineGroups` extension; LibreOffice keeps the same in ODS
/// as `calcext:sparkline-groups`, so the model is neutral and both writers carry them. Numbers has none.
public struct SparklineGroup: Hashable, Sendable {
    /// The kind. A struct with static members rather than an enum (B.69); the raw value is OOXML's `type`.
    public struct Kind: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let line = Kind(rawValue: "line")
        public static let column = Kind(rawValue: "column")
        /// Win / loss: every value a bar of the same height, up or down.
        public static let stacked = Kind(rawValue: "stacked")
        public var description: String { rawValue }
    }
    /// What an empty cell in the data does to the line (fixed at three by the specification, ST_DispBlanksAs;
    /// `zero` is the file's default when the attribute is absent).
    public enum EmptyCells: String, Hashable, Sendable, CaseIterable {
        case gap, zero, span
    }
    /// One sparkline: the numbers it draws (`'Data'!B2:M2` or `B2:M2` — an unqualified range is the host sheet's)
    /// and the cell it is drawn in.
    public struct Sparkline: Hashable, Sendable {
        /// The numbers it draws, as a range in text (`'Data'!B2:M2`, or `B2:M2` for the host sheet).
        public var dataRange: String
        /// The cell it is drawn in.
        public var location: CellRef
        public init(dataRange: String, at location: CellRef) { self.dataRange = dataRange; self.location = location }
    }

    /// How every sparkline of the group is drawn.
    public var kind: Kind
    /// The sparklines, each a data range and the cell it is drawn in; they share the group's look.
    public var sparklines: [Sparkline]
    /// The series colour (nil: the application's default).
    public var color: Color?
    /// The colour of the points below zero, when `showsNegativePoints` (nil: the application's default).
    public var negativeColor: Color?
    /// The colour of the horizontal axis, when `showsAxis` (nil: the application's default).
    public var axisColor: Color?
    /// The colour of the highest point, when `showsHighPoint` (nil: the application's default).
    public var highColor: Color?
    /// The colour of the lowest point, when `showsLowPoint` (nil: the application's default).
    public var lowColor: Color?
    /// The colour of the first point, when `showsFirstPoint` (nil: the application's default).
    public var firstColor: Color?
    /// The colour of the last point, when `showsLastPoint` (nil: the application's default).
    public var lastColor: Color?
    /// The colour of the markers, when `showsMarkers` (nil: the application's default).
    public var markersColor: Color?
    /// Mark the highest point.
    public var showsHighPoint = false
    /// Mark the lowest point.
    public var showsLowPoint = false
    /// Mark the first point.
    public var showsFirstPoint = false
    /// Mark the last point.
    public var showsLastPoint = false
    /// Mark every point below zero.
    public var showsNegativePoints = false
    /// Mark every point of a line sparkline.
    public var showsMarkers = false
    /// The horizontal axis at zero.
    public var showsAxis = false
    /// The line's width in points (nil: the default, 0.75).
    public var lineWidth: Double?
    /// How an empty cell in a data range is drawn: as a gap, as zero (the default), or spanned by the line.
    public var emptyCells: EmptyCells = .zero

    /// A group of `kind` holding `sparklines`, with every colour and marker left to the application.
    public init(_ kind: Kind = .line, sparklines: [Sparkline] = []) {
        self.kind = kind; self.sparklines = sparklines
    }
    /// One sparkline of `kind` drawing `dataRange` into `location`.
    public init(_ kind: Kind = .line, dataRange: String, at location: CellRef) {
        self.init(kind, sparklines: [Sparkline(dataRange: dataRange, at: location)])
    }
}

extension Sheet {
    /// Adds a group with one sparkline drawing `dataRange` into the cell `ref`. An unqualified range is this sheet's.
    public mutating func addSparkline(_ kind: SparklineGroup.Kind = .line, dataRange: String, at ref: CellRef) {
        sparklines.append(SparklineGroup(kind, dataRange: dataRange, at: ref))
    }
    /// Adds a group with one sparkline: `addSparkline(.line, dataRange: "B2:M2", at: "N2")`.
    public mutating func addSparkline(_ kind: SparklineGroup.Kind = .line, dataRange: String, at a1: String) {
        addSparkline(kind, dataRange: dataRange, at: CellRef(a1)!)
    }
}
