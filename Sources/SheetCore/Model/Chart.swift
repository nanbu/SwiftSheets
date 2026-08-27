import Foundation

/// A chart built by this library (spec Appendix B.34) — the four kinds that carry most real work.
///
/// Like pictures (B.32), this is the *adding* side only: charts already in an opened file stay preserved as
/// opaque bytes, and `sheet.charts` holds what `addChart` put in. Series ranges may name their sheet
/// (`'集計'!$B$2:$B$13`) or not (`B2:B13`) — an unqualified range is qualified with the host sheet's name and
/// made absolute at write time, since chart references accept nothing less.
public struct Chart: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// Vertical bars (Excel's "column").
        case column
        /// Horizontal bars.
        case bar
        case line
        /// Drawn without axes, as the format defines it.
        case pie
    }

    /// One plotted series: where its numbers are, optionally where its labels are and what it is called.
    public struct Series: Hashable, Sendable {
        public var values: String
        public var categories: String?
        public var name: String?
        public init(values: String, categories: String? = nil, name: String? = nil) {
            self.values = values; self.categories = categories; self.name = name
        }
    }

    public var kind: Kind
    public var title: String?
    public var series: [Series] = []
    /// The legend, on the right — off when false.
    public var legend = true
    /// Where the chart sits on the sheet, both corners following their cells. Set by `addChart(_:over:)`.
    public var anchor: CellRange?

    public init(_ kind: Kind, title: String? = nil) {
        self.kind = kind; self.title = title
    }

    public mutating func addSeries(values: String, categories: String? = nil, name: String? = nil) {
        series.append(Series(values: values, categories: categories, name: name))
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
