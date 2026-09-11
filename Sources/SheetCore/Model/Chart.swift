import Foundation

/// A chart on a sheet (spec Appendices B.34, B.72): built by `addChart` — the four kinds that carry most real
/// work — or read from a file's drawing, in which case `kind` may be one the writers cannot draw and the chart is
/// written back as the bytes it arrived in until it is changed. Series ranges may name their sheet
/// (`'Summary'!$B$2:$B$13`) or not (`B2:B13`) — an unqualified range is qualified with the host sheet's name and
/// made absolute at write time, since chart references accept nothing less.
public struct Chart: Hashable, Sendable {
    /// The kind of chart. A struct with static members rather than an enum, so a kind can be added without
    /// breaking a caller's `switch` (spec Appendix B.69). The four named here are the ones the writers draw;
    /// a chart read from a file may carry any other kind by its raw name (the OOXML chart-group element, e.g.
    /// `scatterChart`, or the ODF class, e.g. `chart:area`) — it is written back unchanged when untouched, and
    /// reported as dropped when it has to be rebuilt.
    public struct Kind: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Vertical bars (Excel's "column").
        public static let column = Kind(rawValue: "column")
        /// Horizontal bars.
        public static let bar = Kind(rawValue: "bar")
        public static let line = Kind(rawValue: "line")
        /// Drawn without axes, as the format defines it.
        public static let pie = Kind(rawValue: "pie")
        /// The kinds every writer can draw.
        package static let drawable: [Kind] = [.column, .bar, .line, .pie]
        /// Whether the writers can draw this kind (`column`, `bar`, `line`, `pie`).
        public var isDrawable: Bool { Kind.drawable.contains(self) }
        public var description: String { rawValue }
    }

    /// One plotted series: where its numbers are, optionally where its labels are and what it is called.
    public struct Series: Hashable, Sendable {
        public var values: String
        public var categories: String?
        /// The series' name as text.
        public var name: String?
        /// The series' name as a reference to a cell (`'Data'!$B$1`), the way Excel usually records it; when
        /// both are set, the reference is what is written.
        public var nameReference: String?
        /// A series whose numbers are `values`, a range as text; the other arguments are described on their properties.
        public init(values: String, categories: String? = nil, name: String? = nil, nameReference: String? = nil) {
            self.values = values; self.categories = categories; self.name = name; self.nameReference = nameReference
        }
    }

    public var kind: Kind
    public var title: String?
    public var series: [Series] = []
    /// The legend, on the right — off when false.
    public var legend = true
    /// Where the chart sits on the sheet, both corners following their cells. Set by `addChart(_:over:)`.
    public var anchor: CellRange?
    /// Where the chart stands on a Numbers canvas, in points (spec Appendix B.88). Set by the Numbers reader; the
    /// XLSX and ODS writers place a chart that has a frame but no anchor over the cells the frame covers on the
    /// default grid, and the Numbers writer draws it at the frame when there is no anchor.
    public var frame: CanvasRect?

    public init(_ kind: Kind, title: String? = nil) {
        self.kind = kind; self.title = title
    }

    /// Appends a series. `values` and `categories` are ranges as text (`'Data'!$B$2:$B$13`, or `B2:B13`, which is
    /// qualified with the host sheet's name when the chart is added); `name` is literal text, `nameReference` a cell.
    public mutating func addSeries(values: String, categories: String? = nil, name: String? = nil, nameReference: String? = nil) {
        series.append(Series(values: values, categories: categories, name: name, nameReference: nameReference))
    }
}

extension Chart {
    /// The cells a canvas frame covers on Numbers' default grid (98 pt columns, 20 pt rows): the anchor a writer
    /// that places charts by cells uses for a chart that only has a frame.
    package var anchorOrFrameCells: CellRange? {
        if let anchor { return anchor }
        guard let f = frame else { return nil }
        let c0 = Int(f.origin.x / 98) + 1, r0 = Int(f.origin.y / 20) + 1
        let c1 = Swift.max(c0, Int((f.origin.x + f.width - 1) / 98) + 1), r1 = Swift.max(r0, Int((f.origin.y + f.height - 1) / 20) + 1)
        return CellRange(minRow: r0, minColumn: c0, maxRow: r1, maxColumn: c1)
    }
}

extension Sheet {
    /// Places a chart over a range (spec Appendix B.34). It rides the same drawing part as pictures: a sheet
    /// that already carries one — a source file's chart, an added image — gets the anchor appended.
    public mutating func addChart(_ chart: Chart, over range: CellRange) {
        var c = chart
        c.anchor = range
        charts.append(c)
    }
    /// A1 form of `addChart(_:over:)`. An unparseable range is a programmer error, as with subscripts.
    public mutating func addChart(_ chart: Chart, over a1: String) { addChart(chart, over: CellRange(a1)!) }
}
