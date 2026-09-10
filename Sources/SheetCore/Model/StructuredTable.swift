import Foundation

/// A named table over a rectangle of cells — Excel's "Format as Table", openpyxl's `Table`, the format's
/// `xl/tables/tableN.xml`. Its name is usable in formulas (`SUM(Sales[Amount])`), its header row filters, and its
/// banding follows rows added to it.
///
/// Not to be confused with `Table`, the grid a sheet's cells live in: that one is the paper, this one is a frame
/// drawn on it. A sheet may carry several, and they may not overlap.
public struct StructuredTable: Hashable, Sendable {
    /// The name formulas use. Must start with a letter or underscore and hold no spaces — `sanitizedName(_:)`
    /// makes an acceptable one out of anything.
    public var name: String
    /// The name Excel shows in the name box. Almost always the same as `name`; a file may differ.
    public var displayName: String
    /// The cells the table covers, header and totals rows included.
    public var ref: CellRange
    /// 1 when the first row of `ref` holds the column names (the usual case), 0 for a table with no header.
    public var headerRowCount: Int
    /// 1 when the last row of `ref` is a totals row.
    public var totalsRowCount: Int
    /// Excel remembers a totals row that is currently switched off.
    public var totalsRowShown: Bool
    public var columns: [StructuredTableColumn]
    /// The banding and the built-in look (`<tableStyleInfo>`).
    public var styleInfo: TableStyleInfo?
    /// The filter over the table's own header row. Usually the whole `ref`; nil for a table without filter buttons.
    public var autoFilter: CellRange?
    /// What each filtered column of the table lets through.
    public var filterColumns: [FilterColumn]
    /// The tooltip Excel shows for the table.
    public var comment: String?
    /// "worksheet" (the ordinary kind), "queryTable" or "xml". Nil is the ordinary kind.
    public var tableType: String?

    /// Attributes of the source's `<table>` element the model does not carry (`insertRow`, `published`, the
    /// `…DxfId` links), re-emitted verbatim so a round trip keeps them.
    package var otherAttributes: [String: String] = [:]
    /// Children of the source's `<table>` the model does not carry (`sortState`, `extLst`), verbatim.
    package var fragments: [XMLFragment] = []
    /// The source part path and relationship id, reused on a write-back.
    package var partPath: String?
    package var relationshipId: String?
    package var sourceID: Int?

    public init(name: String, ref: CellRange, columns: [StructuredTableColumn] = [], displayName: String? = nil,
                headerRowCount: Int = 1, totalsRowCount: Int = 0, totalsRowShown: Bool = false,
                styleInfo: TableStyleInfo? = .default, autoFilter: CellRange? = nil,
                filterColumns: [FilterColumn] = [], comment: String? = nil, tableType: String? = nil) {
        self.name = name
        self.displayName = displayName ?? name
        self.ref = ref
        self.columns = columns
        self.headerRowCount = headerRowCount
        self.totalsRowCount = totalsRowCount
        self.totalsRowShown = totalsRowShown
        self.styleInfo = styleInfo
        self.autoFilter = autoFilter ?? (headerRowCount > 0 ? ref : nil)
        self.filterColumns = filterColumns
        self.comment = comment
        self.tableType = tableType
    }

    /// A table over `ref` whose column names are read out of the sheet's own header row.
    ///
    /// Excel insists that every column have a name and that no two be the same, so a blank header cell becomes
    /// "Column N" and a repeat gets a numeric suffix — the same repair Excel itself makes.
    public init(name: String, ref: CellRange, headerRow: [CellValue?], displayName: String? = nil,
                totalsRowCount: Int = 0, styleInfo: TableStyleInfo? = .default) {
        var names: [String] = []
        for (i, value) in headerRow.enumerated() {
            var candidate = value?.stringValue ?? ""
            if candidate.isEmpty { candidate = "Column\(i + 1)" }
            var unique = candidate, n = 1
            while names.contains(where: { $0.lowercased() == unique.lowercased() }) { n += 1; unique = candidate + String(n) }
            names.append(unique)
        }
        self.init(name: name, ref: ref, columns: names.enumerated().map { StructuredTableColumn(id: $0.offset + 1, name: $0.element) },
                  displayName: displayName, headerRowCount: 1, totalsRowCount: totalsRowCount, styleInfo: styleInfo)
    }

    /// Two tables are the same when they frame the same cells the same way. The part path, the relationship id and
    /// the numeric id are provenance — which file this table came out of — and take no part in that.
    public static func == (a: StructuredTable, b: StructuredTable) -> Bool {
        a.name == b.name && a.displayName == b.displayName && a.ref == b.ref
            && a.headerRowCount == b.headerRowCount && a.totalsRowCount == b.totalsRowCount
            && a.totalsRowShown == b.totalsRowShown && a.columns == b.columns && a.styleInfo == b.styleInfo
            && a.autoFilter == b.autoFilter && a.filterColumns == b.filterColumns && a.comment == b.comment
            && a.tableType == b.tableType && a.otherAttributes == b.otherAttributes && a.fragments == b.fragments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name); hasher.combine(displayName); hasher.combine(ref)
        hasher.combine(headerRowCount); hasher.combine(totalsRowCount); hasher.combine(totalsRowShown)
        hasher.combine(columns); hasher.combine(styleInfo); hasher.combine(autoFilter)
        hasher.combine(filterColumns); hasher.combine(comment); hasher.combine(tableType)
        hasher.combine(otherAttributes); hasher.combine(fragments)
    }

    /// The rows of `ref` that hold data — the whole range less its header and totals rows. Nil when the table is
    /// all header and totals.
    public var dataRows: ClosedRange<Int>? {
        let first = ref.topLeft.row + headerRowCount
        let last = ref.bottomRight.row - totalsRowCount
        return first <= last ? first...last : nil
    }

    /// Column names must be unique and non-empty; the reference must be at least as wide as the column list, and
    /// tall enough for the header and totals rows it declares. Throws `SheetError.invalidWorkbook` with the reason
    /// when the table is not one a file could hold; a writer drops such a table with that reason as a warning.
    public func validate() throws {
        if name.isEmpty { throw SheetError.invalidWorkbook("a table needs a name") }
        if columns.isEmpty { throw SheetError.invalidWorkbook("table \"\(name)\" has no columns") }
        let width = ref.bottomRight.column - ref.topLeft.column + 1
        if columns.count != width { throw SheetError.invalidWorkbook("table \"\(name)\" covers \(width) column(s) but names \(columns.count)") }
        let height = ref.bottomRight.row - ref.topLeft.row + 1
        if height < headerRowCount + totalsRowCount { throw SheetError.invalidWorkbook("table \"\(name)\" is too short for its header and totals rows") }
        var seen = Set<String>()
        for c in columns {
            if c.name.isEmpty { throw SheetError.invalidWorkbook("table \"\(name)\" has an unnamed column") }
            if !seen.insert(c.name.lowercased()).inserted { throw SheetError.invalidWorkbook("table \"\(name)\" names the column \"\(c.name)\" twice") }
        }
    }

    /// A name Excel accepts: no spaces, no punctuation it reserves, and not starting with a digit.
    public static func sanitizedName(_ proposed: String) -> String {
        var out = ""
        for ch in proposed {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." { out.append(ch) } else { out.append("_") }
        }
        if out.isEmpty { return "Table1" }
        if let first = out.first, first.isNumber { out = "_" + out }
        return out
    }
}

/// One column of an `StructuredTable` (`<tableColumn>`). `name` is what the header cell shows and what formulas use.
public struct StructuredTableColumn: Hashable, Sendable {
    /// What the totals row shows under this column. Nil — the file's "none" — shows nothing.
    public enum TotalsRowFunction: String, Hashable, Sendable, CaseIterable {
        case sum, min, max, average, count
        case countNumbers = "countNums"
        case standardDeviation = "stdDev"
        case variance = "var"
        case custom
    }
    /// Unique within the table, and never renumbered — Excel's calculated columns refer to it.
    public var id: Int
    public var name: String
    /// The label shown in the totals row when the column totals nothing ("合計", "Total").
    public var totalsRowLabel: String?
    /// The function the totals row applies: "sum", "count", "countNums", "average", "max", "min", "stdDev", "var",
    /// or "custom" together with `totalsRowFormula`.
    public var totalsRowFunction: TotalsRowFunction?
    /// The totals-row formula, when `totalsRowFunction` is `.custom`.
    public var totalsRowFormula: String?
    /// The formula Excel fills the whole column with (`<calculatedColumnFormula>`), as text without the `=`.
    public var calculatedColumnFormula: String?

    public init(id: Int, name: String, totalsRowLabel: String? = nil, totalsRowFunction: TotalsRowFunction? = nil,
                totalsRowFormula: String? = nil, calculatedColumnFormula: String? = nil) {
        self.id = id; self.name = name; self.totalsRowLabel = totalsRowLabel
        self.totalsRowFunction = totalsRowFunction; self.totalsRowFormula = totalsRowFormula
        self.calculatedColumnFormula = calculatedColumnFormula
    }
}

/// How a table is banded and which of Excel's built-in table looks it wears (`<tableStyleInfo>`).
public struct TableStyleInfo: Hashable, Sendable {
    /// One of Excel's own names — "TableStyleLight1"…"TableStyleDark11", "TableStyleMedium9". Nil is no style at
    /// all, which leaves the cells' own formatting showing.
    public var name: String?
    public var showsFirstColumn: Bool
    public var showsLastColumn: Bool
    public var showsRowStripes: Bool
    public var showsColumnStripes: Bool

    public init(name: String? = nil, showsFirstColumn: Bool = false, showsLastColumn: Bool = false,
                showsRowStripes: Bool = true, showsColumnStripes: Bool = false) {
        self.name = name; self.showsFirstColumn = showsFirstColumn; self.showsLastColumn = showsLastColumn
        self.showsRowStripes = showsRowStripes; self.showsColumnStripes = showsColumnStripes
    }

    /// The blue banding Excel gives a new table.
    public static let `default` = TableStyleInfo(name: "TableStyleMedium9")
}
