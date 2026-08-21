import Foundation

/// One cell of a worksheet. Reference type, like openpyxl's `Cell`: `ws["A1"].value = ...` mutates the sheet.
public final class Cell {
    public let row: Int
    public let column: Int
    public var value: CellValue?
    public var style = CellStyle.default
    public var hyperlink: Hyperlink?
    public var comment: String?

    init(row: Int, column: Int) { self.row = row; self.column = column }

    public var reference: CellReference { CellReference(column: column, row: row) }
    /// "A1"
    public var coordinate: String { reference.description }
    public var columnLetter: String { reference.columnLetter }

    // Style conveniences (openpyxl: cell.font = Font(...))
    public var font: Font { get { style.font } set { style.font = newValue } }
    public var fill: PatternFill { get { style.fill } set { style.fill = newValue } }
    public var border: Border { get { style.border } set { style.border = newValue } }
    public var alignment: Alignment { get { style.alignment } set { style.alignment = newValue } }
    public var protection: Protection { get { style.protection } set { style.protection = newValue } }
    public var numberFormat: String { get { style.numberFormat } set { style.numberFormat = newValue } }

    /// True when the number format renders the value as a date or time.
    public var isDate: Bool { NumberFormat.isDateFormat(style.numberFormat) }

    public var isEmpty: Bool { value == nil }
}

public struct Hyperlink: Hashable, Sendable {
    public var target: String
    public var tooltip: String?
    public var isInternal: Bool
    public init(target: String, tooltip: String? = nil, isInternal: Bool = false) { self.target = target; self.tooltip = tooltip; self.isInternal = isInternal }
}

/// Row formatting (openpyxl RowDimension).
public struct RowDimension: Hashable, Sendable {
    public var height: Double?
    public var hidden = false
    public var outlineLevel = 0
    public var collapsed = false
    public init(height: Double? = nil, hidden: Bool = false, outlineLevel: Int = 0, collapsed: Bool = false) {
        self.height = height; self.hidden = hidden; self.outlineLevel = outlineLevel; self.collapsed = collapsed
    }
    var isDefault: Bool { height == nil && !hidden && outlineLevel == 0 && !collapsed }
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
    var isDefault: Bool { width == nil && !hidden && outlineLevel == 0 && !collapsed && !bestFit && style == nil }
}

public struct SheetProperties: Hashable, Sendable {
    public var tabColor: Color?
    /// Where the summary row of an outline group sits (Excel default: below; set false for "parent row above").
    public var summaryBelow = true
    public var summaryRight = true
    public init() {}
}

public struct SheetView: Hashable, Sendable {
    public var showGridLines = true
    public var zoomScale = 100
    public var tabSelected = false
    public init() {}
}

public struct PageMargins: Hashable, Sendable {
    public var left = 0.75, right = 0.75, top = 1.0, bottom = 1.0, header = 0.5, footer = 0.5
    public init() {}
}

public struct PageSetup: Hashable, Sendable {
    public enum Orientation: String, Sendable { case portrait, landscape }
    public var orientation: Orientation?
    public var paperSize: Int?
    public var fitToWidth: Int?
    public var fitToHeight: Int?
    public var scale: Int?
    public init() {}
}

public enum SheetState: String, Sendable {
    case visible, hidden, veryHidden
}
