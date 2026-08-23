import Foundation

/// One `<conditionalFormatting>` block: some cells, and the rules that repaint them when what they hold satisfies a
/// condition. A sheet has a list of these; a cell may be covered by several.
public struct ConditionalFormatting: Hashable, Sendable {
    /// The cells the rules cover (`sqref`).
    public var ranges: MultiCellRange
    public var rules: [ConditionalFormattingRule]
    /// The block belongs to a pivot table rather than to the sheet's own cells.
    public var pivot: Bool

    public init(ranges: MultiCellRange, rules: [ConditionalFormattingRule], pivot: Bool = false) {
        self.ranges = ranges; self.rules = rules; self.pivot = pivot
    }
    public init?(_ sqref: String, rules: [ConditionalFormattingRule], pivot: Bool = false) {
        guard let r = MultiCellRange(sqref) else { return nil }
        self.init(ranges: r, rules: rules, pivot: pivot)
    }
}

/// One rule of a conditional format (`<cfRule>`).
///
/// Which fields matter depends on `kind`, and the static builders below set the right ones — `.cellIs`, `.expression`,
/// `.colorScale`, `.dataBar`, `.iconSet` and the text / date / rank rules each use their own. What every kind shares
/// is `priority` (which rule wins where several cover a cell — lower first) and `style` (what it paints).
///
/// Priorities are the sheet's, not the block's, and Excel wants them distinct. The writer therefore renumbers them
/// 1…n over the whole sheet, keeping the order the priorities already gave.
public struct ConditionalFormattingRule: Hashable, Sendable {
    /// The condition's shape. The names are the file format's own so that nothing is lost in translation.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The cell's value, compared with `operator` against `formulas`.
        case cellIs
        /// Any formula: the rule holds where it evaluates true.
        case expression
        /// A colour ramp across the range's values.
        case colorScale
        /// A bar drawn inside each cell, in proportion to its value.
        case dataBar
        /// An icon per cell, chosen by which band the value falls into.
        case iconSet
        /// The highest (or lowest) `rank` values, or `rank` per cent of them.
        case top10
        /// Values above (or below) the range's own average.
        case aboveAverage
        case uniqueValues
        case duplicateValues
        case containsText
        case notContainsText
        case beginsWith
        case endsWith
        case containsBlanks
        case notContainsBlanks
        case containsErrors
        case notContainsErrors
        /// Dates falling in `timePeriod` ("today", "lastWeek", …).
        case timePeriod
    }

    /// How `formulas` bound the cell's value for a `.cellIs` rule.
    public enum Operator: String, Hashable, Sendable, CaseIterable {
        case lessThan, lessThanOrEqual, equal, notEqual, greaterThanOrEqual, greaterThan, between, notBetween,
             containsText, notContains, beginsWith, endsWith
    }

    public var kind: Kind
    /// Which rule wins where several cover a cell — lower first.
    public var priority: Int
    /// Where this rule holds, stop evaluating the ones after it.
    public var stopIfTrue: Bool
    /// What the rule paints where it holds. Nil for `.colorScale` / `.dataBar` / `.iconSet`, which paint themselves.
    public var style: DifferentialStyle?
    /// Where this rule's format sat in the source file's table (`dxfId`), so an untouched rule keeps that entry —
    /// including whatever the model could not read out of it.
    public package(set) var sourceStyleID: Int?
    /// The `<formula>` children, as text without a leading `=`. One for most kinds, two for `.between`.
    public var formulas: [String]
    public var `operator`: Operator?
    /// The text a `.containsText` / `.beginsWith` / `.endsWith` rule looks for.
    public var text: String?
    /// A `.timePeriod` rule's period, verbatim: "today", "yesterday", "last7Days", "thisMonth", "lastWeek", …
    public var timePeriod: String?
    /// How many values a `.top10` rule takes.
    public var rank: Int?
    /// `.top10`: from the bottom instead of the top.
    public var bottom: Bool
    /// `.top10`: `rank` is a percentage of the values rather than a count.
    public var percent: Bool
    /// `.aboveAverage`: below the average instead (the attribute is spelled `aboveAverage` and defaults to true).
    public var aboveAverage: Bool
    /// `.aboveAverage`: a value exactly equal to the average counts too.
    public var equalAverage: Bool
    /// `.aboveAverage`: this many standard deviations out rather than the average itself.
    public var standardDeviation: Int?
    public var colorScale: ColorScale?
    public var dataBar: DataBar?
    public var iconSet: IconSet?

    public init(kind: Kind, priority: Int = 1, stopIfTrue: Bool = false, style: DifferentialStyle? = nil,
                formulas: [String] = [], operator: Operator? = nil, text: String? = nil, timePeriod: String? = nil,
                rank: Int? = nil, bottom: Bool = false, percent: Bool = false, aboveAverage: Bool = true,
                equalAverage: Bool = false, standardDeviation: Int? = nil, colorScale: ColorScale? = nil,
                dataBar: DataBar? = nil, iconSet: IconSet? = nil) {
        self.kind = kind; self.priority = priority; self.stopIfTrue = stopIfTrue; self.style = style
        self.formulas = formulas; self.operator = `operator`; self.text = text; self.timePeriod = timePeriod
        self.rank = rank; self.bottom = bottom; self.percent = percent; self.aboveAverage = aboveAverage
        self.equalAverage = equalAverage; self.standardDeviation = standardDeviation
        self.colorScale = colorScale; self.dataBar = dataBar; self.iconSet = iconSet
    }

    package mutating func setSourceStyleID(_ id: Int?) { sourceStyleID = id }

    /// Two rules are the same when they paint the same cells the same way. `sourceStyleID` is provenance — which
    /// entry of *some* file's format table this rule came from — and takes no part in that, so a rule survives a
    /// round trip as an equal, not as a look-alike.
    public static func == (a: ConditionalFormattingRule, b: ConditionalFormattingRule) -> Bool {
        a.kind == b.kind && a.priority == b.priority && a.stopIfTrue == b.stopIfTrue && a.style == b.style
            && a.formulas == b.formulas && a.operator == b.operator && a.text == b.text
            && a.timePeriod == b.timePeriod && a.rank == b.rank && a.bottom == b.bottom && a.percent == b.percent
            && a.aboveAverage == b.aboveAverage && a.equalAverage == b.equalAverage
            && a.standardDeviation == b.standardDeviation && a.colorScale == b.colorScale
            && a.dataBar == b.dataBar && a.iconSet == b.iconSet
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind); hasher.combine(priority); hasher.combine(stopIfTrue); hasher.combine(style)
        hasher.combine(formulas); hasher.combine(`operator`); hasher.combine(text); hasher.combine(timePeriod)
        hasher.combine(rank); hasher.combine(bottom); hasher.combine(percent); hasher.combine(aboveAverage)
        hasher.combine(equalAverage); hasher.combine(standardDeviation)
        hasher.combine(colorScale); hasher.combine(dataBar); hasher.combine(iconSet)
    }

    // MARK: - The rules people actually write

    /// The cell's value compared against one operand — `.cellIs(.greaterThan, "100", paint: …)`.
    public static func cellIs(_ op: Operator, _ formula: String, paint style: DifferentialStyle,
                              priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .cellIs, priority: priority, style: style, formulas: [formula], operator: op)
    }

    /// The cell's value between two operands (inclusive, as Excel's own `between` is).
    public static func cellIs(between low: String, and high: String, paint style: DifferentialStyle,
                              priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .cellIs, priority: priority, style: style, formulas: [low, high], operator: .between)
    }

    /// Any formula, written relative to the top-left cell of the range the rule covers: a rule over `A2:D99` whose
    /// formula is `$D2="closed"` tests column D of each row.
    public static func expression(_ formula: String, paint style: DifferentialStyle,
                                  priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .expression, priority: priority, style: style, formulas: [formula])
    }

    /// Cells whose text contains `text`.
    ///
    /// The format stores a text rule as a formula as well as as a condition, and that formula is read relative to
    /// the **first cell of the range the rule covers** — so the anchor matters. `Sheet.addConditionalFormatting`
    /// sets it for you; give `anchoredAt` when building a block by hand.
    public static func contains(_ text: String, paint style: DifferentialStyle, anchoredAt anchor: String = "A1",
                                priority: Int = 1) -> ConditionalFormattingRule {
        var rule = ConditionalFormattingRule(kind: .containsText, priority: priority, style: style,
                                             operator: .containsText, text: text)
        rule.anchorTextFormula(at: anchor)
        return rule
    }

    /// Cells whose text starts (or ends) with `text`.
    public static func begins(with text: String, paint style: DifferentialStyle, anchoredAt anchor: String = "A1",
                              priority: Int = 1) -> ConditionalFormattingRule {
        var rule = ConditionalFormattingRule(kind: .beginsWith, priority: priority, style: style,
                                             operator: .beginsWith, text: text)
        rule.anchorTextFormula(at: anchor)
        return rule
    }
    public static func ends(with text: String, paint style: DifferentialStyle, anchoredAt anchor: String = "A1",
                            priority: Int = 1) -> ConditionalFormattingRule {
        var rule = ConditionalFormattingRule(kind: .endsWith, priority: priority, style: style,
                                             operator: .endsWith, text: text)
        rule.anchorTextFormula(at: anchor)
        return rule
    }

    /// Rewrites the formula of a text rule so that it reads the cell at `anchor` — the first cell of the range the
    /// rule covers. Rules of other kinds, and rules whose formula was written by hand, are left alone.
    public mutating func anchorTextFormula(at anchor: String) {
        guard let text else { return }
        let quoted = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let n = text.count
        switch kind {
        case .containsText: formulas = ["NOT(ISERROR(SEARCH(\(quoted),\(anchor))))"]
        case .notContainsText: formulas = ["ISERROR(SEARCH(\(quoted),\(anchor)))"]
        case .beginsWith: formulas = ["LEFT(\(anchor),\(n))=\(quoted)"]
        case .endsWith: formulas = ["RIGHT(\(anchor),\(n))=\(quoted)"]
        default: break
        }
    }

    /// The highest `count` values (or the lowest, or a percentage of them).
    public static func top(_ count: Int, paint style: DifferentialStyle, bottom: Bool = false, percent: Bool = false,
                           priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .top10, priority: priority, style: style, rank: count, bottom: bottom, percent: percent)
    }

    /// Values above the range's own average (or below it).
    public static func aboveAverage(_ above: Bool = true, paint style: DifferentialStyle,
                                    priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .aboveAverage, priority: priority, style: style, aboveAverage: above)
    }

    /// The values that appear more than once (or exactly once).
    public static func duplicates(paint style: DifferentialStyle, unique: Bool = false,
                                  priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: unique ? .uniqueValues : .duplicateValues, priority: priority, style: style)
    }

    /// A colour ramp from the lowest value to the highest, optionally through a midpoint.
    public static func colorScale(_ scale: ColorScale, priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .colorScale, priority: priority, colorScale: scale)
    }

    /// A bar drawn inside each cell in proportion to its value.
    public static func dataBar(_ bar: DataBar, priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .dataBar, priority: priority, dataBar: bar)
    }

    /// An icon per cell, chosen by which band its value falls into.
    public static func iconSet(_ icons: IconSet, priority: Int = 1) -> ConditionalFormattingRule {
        ConditionalFormattingRule(kind: .iconSet, priority: priority, iconSet: icons)
    }
}

/// One boundary of a colour scale, data bar or icon set (`<cfvo>`): where a band starts, and how that place is
/// reckoned — an absolute number, a percentage of the range, a percentile, a formula, or the range's own end.
public struct ConditionalValue: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// An absolute value.
        case num
        /// A percentage of the way from the lowest value to the highest.
        case percent
        /// The highest value in the range.
        case max
        /// The lowest value in the range.
        case min
        /// A formula giving the boundary.
        case formula
        /// The value below which that percentage of the range's values fall.
        case percentile
    }
    public var kind: Kind
    /// The number, percentage or formula text; nil for `.min` / `.max`.
    public var value: String?
    /// Icon sets only: a value exactly on the boundary belongs to the band above it (`gte`, Excel's default).
    public var greaterThanOrEqual: Bool

    public init(_ kind: Kind, _ value: String? = nil, greaterThanOrEqual: Bool = true) {
        self.kind = kind; self.value = value; self.greaterThanOrEqual = greaterThanOrEqual
    }
    public static let min = ConditionalValue(.min)
    public static let max = ConditionalValue(.max)
    public static func percent(_ v: Int) -> ConditionalValue { ConditionalValue(.percent, String(v)) }
    public static func percentile(_ v: Int) -> ConditionalValue { ConditionalValue(.percentile, String(v)) }
    public static func number(_ v: String) -> ConditionalValue { ConditionalValue(.num, v) }
}

/// A colour ramp over a range's values: two boundaries and two colours, or three of each.
public struct ColorScale: Hashable, Sendable {
    public var values: [ConditionalValue]
    public var colors: [Color]
    public init(values: [ConditionalValue], colors: [Color]) { self.values = values; self.colors = colors }

    /// Lowest value `from`, highest value `to`.
    public static func twoColor(from low: Color, to high: Color) -> ColorScale {
        ColorScale(values: [.min, .max], colors: [low, high])
    }
    /// Lowest, midpoint (the 50th percentile by default) and highest.
    public static func threeColor(from low: Color, through mid: Color, to high: Color,
                                  midpoint: ConditionalValue = .percentile(50)) -> ColorScale {
        ColorScale(values: [.min, midpoint, .max], colors: [low, mid, high])
    }
}

/// A bar drawn inside each cell, as long as the value is large (`<dataBar>`).
public struct DataBar: Hashable, Sendable {
    public var minimum: ConditionalValue
    public var maximum: ConditionalValue
    public var color: Color
    /// The shortest bar, as a percentage of the cell's width (Excel's own default is 10).
    public var minLength: Int?
    /// The longest bar (Excel's own default is 90).
    public var maxLength: Int?
    /// Show the number as well as the bar.
    public var showValue: Bool

    public init(color: Color, minimum: ConditionalValue = .min, maximum: ConditionalValue = .max,
                minLength: Int? = nil, maxLength: Int? = nil, showValue: Bool = true) {
        self.color = color; self.minimum = minimum; self.maximum = maximum
        self.minLength = minLength; self.maxLength = maxLength; self.showValue = showValue
    }
}

/// An icon per cell, chosen by which band the value falls into (`<iconSet>`).
public struct IconSet: Hashable, Sendable {
    /// The set's name, verbatim: "3Arrows", "3TrafficLights1", "4Rating", "5Quarters"… The leading digit is how
    /// many icons it has, and therefore how many boundaries `values` needs.
    public var name: String
    /// The band boundaries, the first of which is always the bottom of the range.
    public var values: [ConditionalValue]
    /// Show the number as well as the icon.
    public var showValue: Bool
    /// The boundaries are percentages rather than absolute values.
    public var percent: Bool
    /// Use the icons the other way round.
    public var reverse: Bool

    public init(name: String, values: [ConditionalValue], showValue: Bool = true, percent: Bool = true, reverse: Bool = false) {
        self.name = name; self.values = values; self.showValue = showValue; self.percent = percent; self.reverse = reverse
    }

    /// The three-band default: 0 %, 33 %, 67 %.
    public static func threeBand(_ name: String = "3TrafficLights1") -> IconSet {
        IconSet(name: name, values: [.percent(0), .percent(33), .percent(67)])
    }
}
