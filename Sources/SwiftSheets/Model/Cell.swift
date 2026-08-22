import Foundation

/// One cell of a worksheet. Reference type, like openpyxl's `Cell`: `ws["A1"].value = ...` mutates the sheet.
public final class Cell {
    public internal(set) var row: Int
    public internal(set) var column: Int
    /// Assigning a date / time / duration sets a matching number format unless the cell already has a date format
    /// (openpyxl `_bind_value`): date → "yyyy-mm-dd", datetime → "yyyy-mm-dd h:mm:ss", time → "h:mm:ss", duration → "[hh]:mm:ss".
    public var value: CellValue? {
        didSet {
            guard let v = value, v.dataType == "d", !NumberFormat.isDateFormat(style.numberFormat) else { return }
            switch v {
            case .date(let dt): style.numberFormat = dt.isMidnight ? NumberFormat.dateYYYYMMDD2 : NumberFormat.dateDatetime
            case .time: style.numberFormat = NumberFormat.dateTime6
            case .duration: style.numberFormat = NumberFormat.dateTimedelta
            default: break
            }
        }
    }
    public var style = CellStyle.default
    /// Setting a hyperlink on an empty cell also makes the target the cell's text, as openpyxl does.
    public var hyperlink: Hyperlink? {
        didSet { if let h = hyperlink, value == nil { value = .string(h.target) } }
    }
    public var comment: Comment?
    weak var worksheet: Worksheet?

    init(row: Int, column: Int, worksheet: Worksheet? = nil) { self.row = row; self.column = column; self.worksheet = worksheet }

    public var reference: CellReference { CellReference(column: column, row: row) }
    /// "A1"
    public var coordinate: String { reference.description }
    public var columnLetter: String { reference.columnLetter }
    /// openpyxl's `data_type`: "n" for numbers and empty cells, "s", "b", "d", "f", "e".
    public var dataType: Character { value?.dataType ?? "n" }

    // Style conveniences (openpyxl: cell.font = Font(...))
    public var font: Font { get { style.font } set { style.font = newValue } }
    public var fill: PatternFill { get { style.fill } set { style.fill = newValue } }
    public var border: Border { get { style.border } set { style.border = newValue } }
    public var alignment: Alignment { get { style.alignment } set { style.alignment = newValue } }
    public var protection: Protection { get { style.protection } set { style.protection = newValue } }
    public var numberFormat: String { get { style.numberFormat } set { style.numberFormat = newValue } }
    /// True when the cell carries any non-default formatting.
    public var hasStyle: Bool { style != .default }

    /// True when the value is a date-like value, or the cell is empty / numeric with a date number format (openpyxl `is_date`).
    public var isDate: Bool {
        switch value {
        case .date, .time, .duration: return true
        case nil, .integer, .number: return NumberFormat.isDateFormat(style.numberFormat)
        default: return false
        }
    }

    public var isEmpty: Bool { value == nil }

    /// The cell `row` rows below and `column` columns right of this one, created on demand (openpyxl `cell.offset`).
    public func offset(row: Int = 0, column: Int = 0) -> Cell? {
        worksheet?.cell(row: self.row + row, column: self.column + column)
    }
}

public struct Hyperlink: Hashable, Sendable {
    public var target: String
    public var tooltip: String?
    public var display: String?
    public var isInternal: Bool
    public init(target: String, tooltip: String? = nil, display: String? = nil, isInternal: Bool = false) {
        self.target = target; self.tooltip = tooltip; self.display = display; self.isInternal = isInternal
    }
    /// The `location` of an in-workbook link (openpyxl `hyperlink.location`), nil for external targets.
    public var location: String? { isInternal ? target : nil }
}

/// A cell note (openpyxl `Comment`). Held in memory and round-tripped through `copyWorksheet`; not yet written to the
/// file (comments need a VML drawing part — roadmap).
public struct Comment: Hashable, Sendable {
    public var text: String
    public var author: String
    public var width: Double = 144
    public var height: Double = 79
    public init(_ text: String, author: String = "") { self.text = text; self.author = author }
}

/// Row formatting (openpyxl RowDimension).
public struct RowDimension: Hashable, Sendable {
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
    var isDefault: Bool { self == RowDimension() }
}

/// Column formatting (openpyxl ColumnDimension), keyed by column letter.
public struct ColumnDimension: Hashable, Sendable {
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
    var isDefault: Bool { self == ColumnDimension() }
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
public struct SheetFormat: Hashable, Sendable {
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

/// `<printOptions>` (openpyxl PrintOptions).
public struct PrintOptions: Hashable, Sendable {
    public var horizontalCentered = false
    public var verticalCentered = false
    public var headings = false
    public var gridLines = false
    public init() {}
}

public enum SheetState: String, Sendable {
    case visible, hidden, veryHidden
}
