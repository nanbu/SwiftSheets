import Foundation

/// A cell's formatting, shared between the cells that were given it. `CellStyle` is 384 bytes: a cell that kept its
/// own copy made every `Cell` half a kilobyte, so a sheet of a million of them cost half a gigabyte before any
/// content. Every cell of an `xf`, and every cell of a styled range, points at one of these instead.
package final class SharedStyle: Sendable {
    package let style: CellStyle
    package init(_ style: CellStyle) { self.style = style }
}

/// A cell's hyperlink and note. Both are rare and together they are over a hundred bytes, so they live behind a
/// reference and an ordinary cell stays three words wide.
package final class CellExtras: Sendable {
    package let hyperlink: Hyperlink?
    package let comment: CellNote?
    package init(hyperlink: Hyperlink?, comment: CellNote?) { self.hyperlink = hyperlink; self.comment = comment }
}

/// One cell: a value (nil when the cell only carries formatting) plus its style, hyperlink and note. A value type —
/// mutate through `Sheet` / `Table` subscripts, or copy out, edit and put back.
///
/// The style and the two rarities are held by reference so that the struct itself is small: a million cells are a
/// normal size for a sheet, and they have to fit in memory all at once (spec §14.11 — v1 is a whole-workbook model).
/// Sharing is invisible from here — `style` reads and writes values, as it always did.
public struct Cell: Hashable, Sendable {
    private var storedValue: CellValue?
    private var styleRef: SharedStyle?
    private var extras: CellExtras?

    public var value: CellValue? {
        get { storedValue }
        set { storedValue = newValue; applyDateFormat() }
    }

    public var style: CellStyle {
        get { styleRef?.style ?? .default }
        set { styleRef = newValue == .default ? nil : SharedStyle(newValue) }
    }

    /// The shared formatting, for codecs that hand the same style to many cells (one `xf`, one range).
    package var sharedStyle: SharedStyle? {
        get { styleRef }
        set { styleRef = newValue }
    }

    /// Setting a hyperlink on an empty cell also makes the target the cell's text, as openpyxl does.
    public var hyperlink: Hyperlink? {
        get { extras?.hyperlink }
        set {
            setExtras(hyperlink: newValue, comment: extras?.comment)
            if let h = newValue, storedValue == nil { value = .text(h.target) }
        }
    }
    public var comment: CellNote? {
        get { extras?.comment }
        set { setExtras(hyperlink: extras?.hyperlink, comment: newValue) }
    }

    private mutating func setExtras(hyperlink: Hyperlink?, comment: CellNote?) {
        extras = hyperlink == nil && comment == nil ? nil : CellExtras(hyperlink: hyperlink, comment: comment)
    }

    public init(value: CellValue? = nil, style: CellStyle = .default, hyperlink: Hyperlink? = nil, comment: CellNote? = nil) {
        storedValue = value
        self.style = style
        setExtras(hyperlink: hyperlink, comment: comment)
        applyDateFormat()
        if let h = hyperlink, storedValue == nil { storedValue = .text(h.target) }
    }

    public static func == (a: Cell, b: Cell) -> Bool {
        a.storedValue == b.storedValue
            && a.extras?.hyperlink == b.extras?.hyperlink && a.extras?.comment == b.extras?.comment
            && (a.styleRef === b.styleRef || a.style == b.style)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storedValue)
        hasher.combine(style)
        hasher.combine(extras?.hyperlink)
        hasher.combine(extras?.comment)
    }

    /// Assigning a date / time / duration sets a matching number format unless the cell already has a date format
    /// (openpyxl `_bind_value`): date → "yyyy-mm-dd", datetime → "yyyy-mm-dd h:mm:ss", time → "h:mm:ss", duration → "[hh]:mm:ss".
    private mutating func applyDateFormat() {
        guard let v = storedValue, v.dataType == "d", !NumberFormat.isDateFormat(style.numberFormat) else { return }
        switch v {
        case .date(let dt): style.numberFormat = dt.isMidnight ? NumberFormat.dateYYYYMMDD2 : NumberFormat.dateDatetime
        case .time: style.numberFormat = NumberFormat.dateTime6
        case .duration: style.numberFormat = NumberFormat.dateTimedelta
        default: break
        }
    }

    /// openpyxl's `data_type`: "n" for numbers and empty cells, "s", "b", "d", "f", "e".
    public var dataType: Character { storedValue?.dataType ?? "n" }

    // Style conveniences (openpyxl: cell.font = Font(...))
    public var font: Font { get { style.font } set { style.font = newValue } }
    public var fill: PatternFill { get { style.fill } set { style.fill = newValue } }
    public var border: Border { get { style.border } set { style.border = newValue } }
    public var alignment: Alignment { get { style.alignment } set { style.alignment = newValue } }
    public var protection: Protection { get { style.protection } set { style.protection = newValue } }
    public var numberFormat: String { get { style.numberFormat } set { style.numberFormat = newValue } }
    /// True when the cell carries any non-default formatting.
    public var hasStyle: Bool { styleRef != nil && styleRef!.style != .default }

    /// True when the value is date-like, or the cell is empty / numeric with a date number format (openpyxl `is_date`).
    public var isDate: Bool {
        switch storedValue {
        case .date, .time, .duration: return true
        case nil, .integer, .number: return NumberFormat.isDateFormat(style.numberFormat)
        default: return false
        }
    }

    public var isEmpty: Bool { storedValue == nil }
    /// True when nothing at all is set — such cells are not worth storing.
    public var isBlank: Bool { storedValue == nil && extras == nil && (styleRef == nil || styleRef!.style == .default) }
}

public struct Hyperlink: Hashable, Sendable {
    public var target: String
    public var tooltip: String?
    public var display: String?
    public var isInternal: Bool
    public init(target: String, tooltip: String? = nil, display: String? = nil, isInternal: Bool = false) {
        self.target = target; self.tooltip = tooltip; self.display = display; self.isInternal = isInternal
    }
    /// The `location` of an in-workbook link, nil for external targets.
    public var location: String? { isInternal ? target : nil }
}

/// A cell note (what Excel calls a comment / note; named `CellNote` so it does not shadow Swift Testing's `Comment`). Held in the model and copied with the sheet; comments read from a file are preserved as opaque
/// parts (they need a VML drawing part, which the writer does not generate yet — roadmap).
public struct CellNote: Hashable, Sendable {
    public var text: String
    public var author: String
    public var width: Double = 144
    public var height: Double = 79
    public init(_ text: String, author: String = "") { self.text = text; self.author = author }
}

/// Row formatting (openpyxl RowDimension).
public struct RowDimension: Hashable, Sendable {
    /// Points.
    public var height: Double?
    public var hidden = false
    public var outlineLevel = 0
    public var collapsed = false
    public var thickTop = false
    public var thickBottom = false
    /// Default style for cells of this row that have no style of their own (`<row s>`).
    public var style: CellStyle?
    public init(height: Double? = nil, hidden: Bool = false, outlineLevel: Int = 0, collapsed: Bool = false, style: CellStyle? = nil) {
        self.height = height; self.hidden = hidden; self.outlineLevel = outlineLevel; self.collapsed = collapsed; self.style = style
    }
    public var isDefault: Bool { self == RowDimension() }
}

/// Column formatting (openpyxl ColumnDimension).
public struct ColumnDimension: Hashable, Sendable {
    /// Characters of the default font (the XLSX unit; ODS writers convert to mm).
    public var width: Double?
    public var hidden = false
    public var outlineLevel = 0
    public var collapsed = false
    public var bestFit = false
    /// Default style for cells of this column that have no style of their own (`<col style>`). Lets a whole column
    /// be filled without creating a cell per row.
    public var style: CellStyle?
    public init(width: Double? = nil, hidden: Bool = false, outlineLevel: Int = 0, collapsed: Bool = false, bestFit: Bool = false, style: CellStyle? = nil) {
        self.width = width; self.hidden = hidden; self.outlineLevel = outlineLevel; self.collapsed = collapsed; self.bestFit = bestFit; self.style = style
    }
    public var isDefault: Bool { self == ColumnDimension() }
}

public struct SheetProperties: Hashable, Sendable {
    public var tabColor: Color?
    /// Where the summary row of an outline group sits (Excel default: below; set false for "parent row above").
    public var summaryBelow = true
    public var summaryRight = true
    /// `<pageSetUpPr fitToPage>` — print scaling to the `fitToWidth` / `fitToHeight` pages of `PageSetup`.
    public var fitToPage: Bool?
    /// VBA code name (`<sheetPr codeName>`), preserved when present.
    public var codeName: String?
    public var filterMode: Bool?
    public init() {}
}

public struct SheetView: Hashable, Sendable {
    public var showGridLines = true
    public var zoomScale = 100
    public var tabSelected = false
    /// The cursor cell of the (last) selection.
    public var activeCell = "A1"
    /// The selected ranges, space separated ("A1" / "A1:B2 D4").
    public var sqref = "A1"
    public init() {}
}

/// `<sheetFormatPr>` — default row height / column width of the sheet.
public struct SheetFormatProperties: Hashable, Sendable {
    public var baseColWidth = 8
    public var defaultColWidth: Double?
    public var defaultRowHeight = 15.0
    public var customHeight = false
    public var zeroHeight = false
    public init() {}
}

public struct PageMargins: Hashable, Sendable {
    public var left = 0.75, right = 0.75, top = 1.0, bottom = 1.0, header = 0.5, footer = 0.5
    public init() {}
}

public struct PageSetup: Hashable, Sendable {
    public enum Orientation: String, Sendable { case `default`, portrait, landscape }
    public var orientation: Orientation?
    public var paperSize: Int?
    public var fitToWidth: Int?
    public var fitToHeight: Int?
    public var scale: Int?
    public var firstPageNumber: Int?
    public var useFirstPageNumber: Bool?
    public init() {}
}

/// What one column of an auto-filter lets through (`<filterColumn>`). The column index is relative to the filter
/// range's first column, as OOXML's `colId` is.
///
/// SwiftSheets models the two filter kinds people actually set by hand: a list of values, and one or two
/// comparisons. Excel's other kinds — colour, icon, dynamic (top 10, above average, this month) — are kept as the
/// source XML instead, so a file that has them writes back unchanged (`Sheet.hasUnmodelledFilters`).
public struct FilterColumn: Hashable, Sendable {
    public var column: Int
    /// The values that pass (`<filters><filter val>`); empty when the column filters by comparison instead.
    public var values: [String]
    /// Blank cells pass too (`<filters blank="1">`).
    public var includesBlanks: Bool
    /// Comparisons that pass (`<customFilters>`); Excel allows at most two.
    public var conditions: [FilterCondition]
    /// Both comparisons must hold (`<customFilters and="1">`); otherwise either does.
    public var matchesAllConditions: Bool
    /// The drop-down button is hidden on this column.
    public var buttonHidden: Bool

    public init(column: Int, values: [String] = [], includesBlanks: Bool = false, conditions: [FilterCondition] = [],
                matchesAllConditions: Bool = false, buttonHidden: Bool = false) {
        self.column = column; self.values = values; self.includesBlanks = includesBlanks
        self.conditions = conditions; self.matchesAllConditions = matchesAllConditions; self.buttonHidden = buttonHidden
    }
}

/// One comparison of a custom filter (`<customFilter operator val>`). The value is the file's text: Excel compares
/// numbers as numbers and text as text, and `*` / `?` are wildcards.
public struct FilterCondition: Hashable, Sendable {
    public enum Comparison: String, Sendable, CaseIterable {
        case equal, notEqual, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    }
    public var comparison: Comparison
    public var value: String
    public init(_ comparison: Comparison, _ value: String) { self.comparison = comparison; self.value = value }
}

/// The sort a sheet's auto-filter last applied (`<sortState>`). Excel stores it; it does not re-sort on open, and
/// neither does SwiftSheets — the rows are already in the file in that order.
public struct SortState: Hashable, Sendable {
    public var range: CellRange
    public var conditions: [SortCondition]
    public var caseSensitive: Bool
    /// Sorting left to right rather than top to bottom.
    public var byColumn: Bool
    public init(range: CellRange, conditions: [SortCondition] = [], caseSensitive: Bool = false, byColumn: Bool = false) {
        self.range = range; self.conditions = conditions; self.caseSensitive = caseSensitive; self.byColumn = byColumn
    }
}

public struct SortCondition: Hashable, Sendable {
    public var range: CellRange
    public var descending: Bool
    public init(range: CellRange, descending: Bool = false) { self.range = range; self.descending = descending }
}

/// Printed page headers and footers (`<headerFooter>`, openpyxl `HeaderFooter`).
///
/// The strings are Excel's own: `&L` / `&C` / `&R` start the left, centre and right sections, `&P` is the page
/// number, `&F` the file name, `&"Arial,Bold"&12` a font change. SwiftSheets carries the code verbatim rather than
/// taking it apart — every reader agrees on what it means, and a round trip cannot lose a code it did not model.
public struct HeaderFooter: Hashable, Sendable {
    public var oddHeader: String?
    public var oddFooter: String?
    /// Used on even pages when `differentOddEven` is set.
    public var evenHeader: String?
    public var evenFooter: String?
    /// Used on the first page when `differentFirst` is set.
    public var firstHeader: String?
    public var firstFooter: String?
    public var differentOddEven = false
    public var differentFirst = false
    /// Scale the header with the sheet's print scaling (Excel's default is true).
    public var scaleWithDoc = true
    /// Align the header with the page margins rather than the printable area (Excel's default is true).
    public var alignWithMargins = true

    public init() {}
    public var isEmpty: Bool { self == HeaderFooter() }
}

/// `<printOptions>` (openpyxl PrintOptions).
public struct PrintOptions: Hashable, Sendable {
    public var horizontalCentered = false
    public var verticalCentered = false
    public var headings = false
    public var gridLines = false
    public init() {}
}

public enum SheetState: String, Sendable, Hashable, Codable {
    case visible, hidden, veryHidden
}
