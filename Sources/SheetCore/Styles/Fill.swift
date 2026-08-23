import Foundation

/// How a cell is painted: with a pattern (a colour, or one of Excel's hatchings) or with a gradient.
///
/// The two are alternatives in the file format and in openpyxl alike — a cell has one fill, and it is either kind.
/// `.none` and `.solid(_:)` cover the everyday cases, so ordinary code never has to name the enum:
///
///     sheet.style("A1:D1") { $0.fill = .solid(Color(hex: "F5F5F7")) }
///     sheet.style("A2") { $0.fill = .gradient(GradientFill(from: .white, to: Color(hex: "BFD7F5"), degree: 90)) }
public enum Fill: Hashable, Sendable {
    case pattern(PatternFill)
    case gradient(GradientFill)

    /// No fill at all.
    public static let none = Fill.pattern(.none)
    /// One flat colour — what "fill a cell" means to almost everyone.
    public static func solid(_ color: Color) -> Fill { .pattern(.solid(color)) }

    public var patternFill: PatternFill? { if case .pattern(let f) = self { return f }; return nil }
    public var gradientFill: GradientFill? { if case .gradient(let f) = self { return f }; return nil }

    /// The pattern, or `.none` for a gradient — so code that only cares whether a cell is painted at all can ask
    /// without taking the enum apart.
    public var patternType: PatternFill.PatternType { patternFill?.patternType ?? .none }
    /// The pattern's foreground, or a gradient's first stop.
    public var foregroundColor: Color? { patternFill?.foregroundColor ?? gradientFill?.stops.first?.color }
    /// The pattern's background, or a gradient's last stop.
    public var backgroundColor: Color? { patternFill?.backgroundColor ?? gradientFill?.stops.last?.color }
    public var isEmpty: Bool { self == .none }
}

/// A fill that runs from one colour to another across the cell (`<gradientFill>`).
///
/// A `.linear` gradient sweeps in a straight line, `degree` clockwise from left to right (90 is top to bottom).
/// A `.path` gradient radiates out of a rectangle inside the cell, which `left` / `right` / `top` / `bottom` place
/// as fractions of the cell's own size — all four at 0.5 is a point in the middle, all four at 0 is the whole cell.
public struct GradientFill: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable { case linear, path }

    /// One colour and where it sits along the sweep, 0 at the start and 1 at the end.
    public struct Stop: Hashable, Sendable, Comparable {
        public var position: Double
        public var color: Color
        public init(_ position: Double, _ color: Color) { self.position = position; self.color = color }
        public static func < (a: Stop, b: Stop) -> Bool { a.position < b.position }
    }

    public var kind: Kind
    /// Degrees clockwise from a left-to-right sweep. Only a `.linear` gradient uses it.
    public var degree: Double
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double
    /// The colour stops, in position order. Two is the usual number.
    public var stops: [Stop]

    public init(kind: Kind = .linear, degree: Double = 0, left: Double = 0, right: Double = 0,
                top: Double = 0, bottom: Double = 0, stops: [Stop] = []) {
        self.kind = kind; self.degree = degree; self.left = left; self.right = right
        self.top = top; self.bottom = bottom; self.stops = stops.sorted()
    }

    /// The two-colour case: from `start` at one edge to `end` at the other.
    public init(from start: Color, to end: Color, degree: Double = 0) {
        self.init(kind: .linear, degree: degree, stops: [Stop(0, start), Stop(1, end)])
    }

    /// Colours radiating out of a rectangle inside the cell; `inset` places all four of its edges at once.
    public static func path(from centre: Color, to edge: Color, inset: Double = 0.5) -> GradientFill {
        GradientFill(kind: .path, left: inset, right: inset, top: inset, bottom: inset,
                     stops: [Stop(0, centre), Stop(1, edge)])
    }
}
