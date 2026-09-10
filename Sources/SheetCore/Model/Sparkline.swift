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
        public var dataRange: String
        public var location: CellRef
        public init(dataRange: String, location: CellRef) { self.dataRange = dataRange; self.location = location }
    }

    public var kind: Kind
    public var sparklines: [Sparkline]
    /// The series colour (nil: the application's default).
    public var color: Color?
    public var negativeColor: Color?
    public var axisColor: Color?
    public var highColor: Color?
    public var lowColor: Color?
    public var firstColor: Color?
    public var lastColor: Color?
    public var markersColor: Color?
    public var showsHighPoint = false
    public var showsLowPoint = false
    public var showsFirstPoint = false
    public var showsLastPoint = false
    public var showsNegativePoints = false
    public var showsMarkers = false
    /// The horizontal axis at zero.
    public var showsAxis = false
    /// The line's width in points (nil: the default, 0.75).
    public var lineWidth: Double?
    public var emptyCells: EmptyCells = .zero

    public init(_ kind: Kind = .line, sparklines: [Sparkline] = []) {
        self.kind = kind; self.sparklines = sparklines
    }
    /// One sparkline of `kind` drawing `dataRange` into `location`.
    public init(_ kind: Kind = .line, dataRange: String, at location: CellRef) {
        self.init(kind, sparklines: [Sparkline(dataRange: dataRange, location: location)])
    }
}

extension Sheet {
    /// Adds a group with one sparkline: `addSparkline(.line, data: "B2:M2", at: "N2")`.
    public mutating func addSparkline(_ kind: SparklineGroup.Kind = .line, data: String, at a1: String) {
        sparklines.append(SparklineGroup(kind, dataRange: data, at: CellRef(a1)!))
    }
}
