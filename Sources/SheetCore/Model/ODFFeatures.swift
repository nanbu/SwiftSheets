import Foundation

/// The things OpenDocument says and OOXML has no word for (spec Appendix B.17).
///
/// Everything here is read and written by the ODS codec and lost — with a warning from the facade — by every other
/// one. They are modelled rather than preserved as opaque XML because ODS is regenerated on every write, so a
/// preserved fragment would have nowhere to go.

// MARK: - Calculation settings

/// How the application is asked to calculate (`table:calculation-settings`).
///
/// Two of these have OOXML equivalents — iteration is Excel's `<calcPr iterate…>`, and `precisionAsShown` is its
/// `fullPrecision="0"`. The rest have none: ODF lets a *document* decide whether a search condition is a regular
/// expression, whether it matches part of a cell or the whole of it, and where the two-digit-year window starts.
/// In Excel those are settings of the application, not of the file, so a workbook cannot carry them.
public struct CalculationSettings: Hashable, Sendable {
    /// Text comparisons in formulas tell upper from lower case.
    public var caseSensitive: Bool
    /// Calculate with the number as displayed rather than as stored.
    public var precisionAsShown: Bool
    /// A search condition has to match the whole cell, not a part of it.
    public var searchCriteriaMustApplyToWholeCell: Bool
    /// Column and row headings may be used in formulas without being declared (see `LabelRange`).
    public var automaticFindLabels: Bool
    /// Search conditions are regular expressions.
    public var useRegularExpressions: Bool
    /// Search conditions use `*` / `?` wildcards.
    public var useWildcards: Bool
    /// The first year of the hundred-year window a two-digit year falls in (`table:null-year`, e.g. 1930).
    public var nullYear: Int?
    /// Recalculate circular references instead of reporting them.
    public var iterationEnabled: Bool
    /// How many times (`table:steps`).
    public var iterationSteps: Int?
    /// Stop when a step moves every value less than this (`table:maximum-difference`).
    public var iterationMaximumDifference: Double?

    /// ODF's own defaults (§9.4.1): everything off except the wildcard and heading conveniences.
    public init(caseSensitive: Bool = false, precisionAsShown: Bool = false,
                searchCriteriaMustApplyToWholeCell: Bool = true, automaticFindLabels: Bool = true,
                useRegularExpressions: Bool = false, useWildcards: Bool = true, nullYear: Int? = nil,
                iterationEnabled: Bool = false, iterationSteps: Int? = nil, iterationMaximumDifference: Double? = nil) {
        self.caseSensitive = caseSensitive
        self.precisionAsShown = precisionAsShown
        self.searchCriteriaMustApplyToWholeCell = searchCriteriaMustApplyToWholeCell
        self.automaticFindLabels = automaticFindLabels
        self.useRegularExpressions = useRegularExpressions
        self.useWildcards = useWildcards
        self.nullYear = nullYear
        self.iterationEnabled = iterationEnabled
        self.iterationSteps = iterationSteps
        self.iterationMaximumDifference = iterationMaximumDifference
    }

    public var isDefault: Bool { self == CalculationSettings() }
}

// MARK: - Label ranges

/// A block of headings that formulas may name directly (`table:label-range`).
///
/// This is ODF's "natural language" addressing: with a label range over `A1:D1` covering the data below it,
/// `=SUM(Sales)` finds the column headed *Sales* — no defined name involved. Excel had the same idea until 2003 and
/// dropped it; OOXML has nothing to write it with.
public struct LabelRange: Hashable, Sendable {
    /// Whether the labels head columns (they sit in a row) or rows (they sit in a column).
    public enum Orientation: String, Hashable, Sendable, CaseIterable { case column, row }

    /// The cells holding the headings. Sheet-qualified.
    public var labels: CellRange
    /// The cells the headings speak for. Sheet-qualified.
    public var data: CellRange
    public var orientation: Orientation

    public init(labels: CellRange, data: CellRange, orientation: Orientation) {
        self.labels = labels; self.data = data; self.orientation = orientation
    }
}

// MARK: - Consolidation

/// A stored "consolidate these ranges into that corner" definition (`table:consolidation`).
///
/// Excel consolidates as a one-off command and keeps nothing; ODF writes the definition into the document so that it
/// can be run again. A document holds at most one.
public struct Consolidation: Hashable, Sendable {
    /// Which of the source ranges' headings line the result up.
    public enum Labels: String, Hashable, Sendable, CaseIterable { case none, row, column, both }

    /// How the sources are combined. The names are ODF's own, and they are the same set a pivot table uses.
    public var function: PivotDataField.Function
    /// The ranges being combined. Sheet-qualified.
    public var sources: [CellRange]
    /// The top-left cell of the result. Sheet-qualified.
    public var target: CellRef
    /// The sheet `target` sits on.
    public var targetSheet: String
    public var useLabels: Labels
    /// Write formulas that follow the sources rather than a snapshot of their values.
    public var linkToSourceData: Bool

    public init(function: PivotDataField.Function = .sum, sources: [CellRange], target: CellRef, targetSheet: String,
                useLabels: Labels = .none, linkToSourceData: Bool = false) {
        self.function = function; self.sources = sources; self.target = target; self.targetSheet = targetSheet
        self.useLabels = useLabels; self.linkToSourceData = linkToSourceData
    }
}

// MARK: - Detective

/// The tracing arrows drawn on one cell (`table:detective`).
///
/// Excel draws the same arrows but never saves them — close the file and they are gone. ODF keeps them, so a
/// document can arrive with an audit already laid out on it.
public struct CellDetective: Hashable, Sendable {
    /// One arrow-drawing command, in the order it was applied.
    public struct Operation: Hashable, Sendable {
        public enum Name: String, Hashable, Sendable, CaseIterable {
            case traceDependents = "trace-dependents"
            case removeDependents = "remove-dependents"
            case tracePrecedents = "trace-precedents"
            case removePrecedents = "remove-precedents"
            case traceErrors = "trace-errors"
        }
        public var name: Name
        /// Where this command sits in the sequence.
        public var index: Int
        public init(_ name: Name, index: Int) { self.name = name; self.index = index }
    }

    /// One range an arrow points at.
    public struct HighlightedRange: Hashable, Sendable {
        public enum Direction: String, Hashable, Sendable, CaseIterable {
            case fromAnotherTable = "from-another-table"
            case toAnotherTable = "to-another-table"
            case fromSameTable = "from-same-table"
        }
        /// Nil when the arrow only says "somewhere on another sheet".
        public var range: CellRange?
        public var direction: Direction
        /// The arrow was drawn by "trace error" rather than by tracing a reference.
        public var containsError: Bool

        public init(range: CellRange?, direction: Direction, containsError: Bool = false) {
            self.range = range; self.direction = direction; self.containsError = containsError
        }
    }

    public var highlighted: [HighlightedRange]
    public var operations: [Operation]

    public init(highlighted: [HighlightedRange] = [], operations: [Operation] = []) {
        self.highlighted = highlighted; self.operations = operations
    }
    public var isEmpty: Bool { highlighted.isEmpty && operations.isEmpty }
}

// MARK: - What a file said and the model cannot

/// ODF material a document carried that SwiftSheets reads but does not model — recorded so that a write can say it
/// is gone rather than dropping it in silence (spec Appendix B.17).
public struct UnmodelledODFFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `table:tracked-changes` — cell-level revision history.
    public static let trackedChanges = UnmodelledODFFeatures(rawValue: 1 << 0)
    /// `table:dde-links` — values fed by another running application.
    public static let ddeLinks = UnmodelledODFFeatures(rawValue: 1 << 1)
    /// `table:table-source` — a whole sheet linked from another document.
    public static let linkedSheet = UnmodelledODFFeatures(rawValue: 1 << 2)
    /// `table:cell-range-source` — a range linked from another document.
    public static let linkedRange = UnmodelledODFFeatures(rawValue: 1 << 3)

    /// What each member should be called when a write reports it.
    public var descriptions: [String] {
        var out: [String] = []
        if contains(.trackedChanges) { out.append("tracked changes (a document's revision history)") }
        if contains(.ddeLinks) { out.append("DDE links (values fed by another running application)") }
        if contains(.linkedSheet) { out.append("a sheet linked from another document") }
        if contains(.linkedRange) { out.append("a range linked from another document") }
        return out
    }
}
