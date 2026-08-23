import Foundation

/// A pivot table: a summary of a range of cells, laid out by whichever of its columns you put down the side, across
/// the top, and into the body (`xl/pivotTables/pivotTableN.xml` plus the cache it reads).
///
/// Two parts of the file make one pivot table. The **cache** (`PivotCache`) is a snapshot of the source range: the
/// column names, and the distinct values found in each. The **table** is the layout: which cached field goes where
/// and how the body is summarised. Both are modelled here, and the cache's own copy of the source rows is not —
/// SwiftSheets writes the table with "refresh when opened" set, so the application fills the numbers in from the
/// source range itself.
///
/// That is the honest limit of this support: **SwiftSheets lays a pivot table out, it does not compute one.** Open
/// the file and the application computes it; read the file back without opening it and the body cells are as the
/// source file left them.
public struct PivotTable: Hashable, Sendable {
    /// The name Excel shows in the field list ("ピボットテーブル1", "PivotTable1").
    public var name: String
    /// Where on the sheet the table is drawn.
    public var location: PivotLocation
    /// One entry per column of the source, in the cache's order. Which of them appear, and where, is `axis`.
    public var fields: [PivotField]
    /// Indices into `fields` of the fields stacked down the left, outermost first.
    public var rowFields: [Int]
    /// …and across the top.
    public var columnFields: [Int]
    /// The fields used as report filters above the table.
    public var pageFields: [PivotPageField]
    /// What the body of the table summarises.
    public var dataFields: [PivotDataField]
    /// The caption over the values area ("値", "Values").
    public var dataCaption: String
    public var showRowGrandTotals: Bool
    public var showColumnGrandTotals: Bool
    /// The banding and built-in look (`<pivotTableStyleInfo>`).
    public var styleInfo: PivotStyleInfo?
    /// The source snapshot this table reads.
    public var cache: PivotCache

    /// Attributes and children of the source's `<pivotTableDefinition>` the model does not carry, verbatim.
    package var otherAttributes: [String: String] = [:]
    package var fragments: [XMLFragment] = []
    package var partPath: String?
    package var relationshipId: String?

    public init(name: String, location: PivotLocation, fields: [PivotField], cache: PivotCache,
                rowFields: [Int] = [], columnFields: [Int] = [], pageFields: [PivotPageField] = [],
                dataFields: [PivotDataField] = [], dataCaption: String = "Values",
                showRowGrandTotals: Bool = true, showColumnGrandTotals: Bool = true,
                styleInfo: PivotStyleInfo? = .default) {
        self.name = name; self.location = location; self.fields = fields; self.cache = cache
        self.rowFields = rowFields; self.columnFields = columnFields; self.pageFields = pageFields
        self.dataFields = dataFields; self.dataCaption = dataCaption
        self.showRowGrandTotals = showRowGrandTotals; self.showColumnGrandTotals = showColumnGrandTotals
        self.styleInfo = styleInfo
    }

    /// The place in `rowFields` / `columnFields` that stands for the value captions rather than for a source
    /// column. A table with more than one value needs it somewhere, or the captions have nowhere to go.
    public static let valuesField = -2

    /// Nil when the table is one the format would accept, else the reason.
    public func validationError() -> String? {
        if name.isEmpty { return "a pivot table needs a name" }
        if cache.fields.isEmpty { return "pivot table \"\(name)\" has no source fields" }
        if fields.count != cache.fields.count {
            return "pivot table \"\(name)\" has \(fields.count) field(s) but its cache has \(cache.fields.count)"
        }
        for i in rowFields + columnFields where !fields.indices.contains(i) && i != PivotTable.valuesField {
            return "pivot table \"\(name)\" places a field (\(i)) it does not have"
        }
        for d in dataFields where !fields.indices.contains(d.field) {
            return "pivot table \"\(name)\" summarises a field (\(d.field)) it does not have"
        }
        for p in pageFields where !fields.indices.contains(p.field) {
            return "pivot table \"\(name)\" filters on a field (\(p.field)) it does not have"
        }
        if dataFields.isEmpty && rowFields.isEmpty && columnFields.isEmpty {
            return "pivot table \"\(name)\" places no fields at all"
        }
        return nil
    }

    /// A pivot table over `source`, laid out at `anchor`, whose header row names the fields.
    ///
    /// `rows`, `columns` and `values` name source columns by their header text; a name that is not among them is
    /// ignored. The table is written with "refresh when opened" set, so the application computes the numbers.
    public static func summarizing(_ source: CellRange, on sourceSheet: String, headerRow: [CellValue?],
                                   named name: String, at anchor: CellRef,
                                   rows: [String] = [], columns: [String] = [], values: [(String, PivotDataField.Function)] = [],
                                   filters: [String] = []) -> PivotTable? {
        let names = headerRow.map { $0?.stringValue ?? "" }
        guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else { return nil }
        var cache = PivotCache(sourceRef: source, sourceSheet: sourceSheet,
                               fields: names.map { PivotCacheField(name: $0) })
        cache.refreshOnLoad = true

        func index(of column: String) -> Int? { names.firstIndex(of: column) }
        let rowIndices = rows.compactMap(index), columnIndices = columns.compactMap(index)
        let valueIndices = values.compactMap { v in index(of: v.0).map { ($0, v.1) } }
        let filterIndices = filters.compactMap(index)

        var fields = names.map { PivotField(name: $0) }
        for i in rowIndices { fields[i].axis = .row }
        for i in columnIndices { fields[i].axis = .column }
        for i in filterIndices { fields[i].axis = .page }
        for (i, _) in valueIndices { fields[i].isDataField = true }

        // more than one value needs somewhere to put the value captions; the format spells that place `-2`, a
        // column field standing for "the values" rather than for a source column
        var columnPlacement = columnIndices
        if valueIndices.count > 1, columnPlacement.isEmpty { columnPlacement = [PivotTable.valuesField] }

        // the table's own rectangle: the filters sit above it, then a header row, then one row per group
        let filterRows = filterIndices.count
        let width = Swift.max(1, rowIndices.count) + Swift.max(1, valueIndices.count)
        let ref = CellRange(from: anchor,
                            to: CellRef(row: anchor.row + filterRows + 2, col: anchor.col + width - 1))
        let location = PivotLocation(ref: ref, firstHeaderRow: 1, firstDataRow: filterRows + 2,
                                     firstDataCol: Swift.max(1, rowIndices.count))
        return PivotTable(name: name, location: location, fields: fields, cache: cache,
                          rowFields: rowIndices, columnFields: columnPlacement,
                          pageFields: filterIndices.map { PivotPageField(field: $0) },
                          dataFields: valueIndices.map { PivotDataField(field: $0, function: $1, name: "\($1.caption) / \(names[$0])") })
    }
}

/// Where a pivot table is drawn, and where its parts begin inside that rectangle (`<location>`). The row and column
/// numbers are counted from the top-left of `ref`, as the file counts them.
public struct PivotLocation: Hashable, Sendable {
    public var ref: CellRange
    /// The row of `ref` that holds the column-field headers.
    public var firstHeaderRow: Int
    /// The first row of the body.
    public var firstDataRow: Int
    /// The first column of the body — everything left of it is row-field labels.
    public var firstDataCol: Int
    /// How many rows / columns the report filters take above the table.
    public var rowPageCount: Int?
    public var columnPageCount: Int?

    public init(ref: CellRange, firstHeaderRow: Int = 1, firstDataRow: Int = 2, firstDataCol: Int = 1,
                rowPageCount: Int? = nil, columnPageCount: Int? = nil) {
        self.ref = ref; self.firstHeaderRow = firstHeaderRow; self.firstDataRow = firstDataRow
        self.firstDataCol = firstDataCol; self.rowPageCount = rowPageCount; self.columnPageCount = columnPageCount
    }
}

/// One source column as the pivot table sees it (`<pivotField>`): whether it appears, and where.
public struct PivotField: Hashable, Sendable {
    /// Where the field is placed. Nil is "in the field list, not on the table".
    public enum Axis: String, Hashable, Sendable, CaseIterable {
        case row = "axisRow"
        case column = "axisCol"
        case page = "axisPage"
        case values = "axisValues"
    }
    /// The caption shown for the field; nil takes the cache field's own name.
    public var name: String?
    public var axis: Axis?
    /// The field is summarised in the body rather than used as a heading.
    public var isDataField: Bool
    /// Show items that no row falls into.
    public var showAll: Bool
    /// Show a subtotal for the field.
    public var defaultSubtotal: Bool
    /// The items the field lists, in the order the table draws them. Excel writes these out even for a table it
    /// will refresh; an empty list is fine for one that has never been opened.
    public var items: [PivotFieldItem]
    package var otherAttributes: [String: String] = [:]

    public init(name: String? = nil, axis: Axis? = nil, isDataField: Bool = false, showAll: Bool = false,
                defaultSubtotal: Bool = true, items: [PivotFieldItem] = []) {
        self.name = name; self.axis = axis; self.isDataField = isDataField
        self.showAll = showAll; self.defaultSubtotal = defaultSubtotal; self.items = items
    }
}

/// One entry in a field's list (`<item>`): either one of the cache's distinct values, or a subtotal line.
public struct PivotFieldItem: Hashable, Sendable {
    /// Index into the cache field's `sharedItems`; nil for a subtotal line.
    public var index: Int?
    /// "default", "sum", "avg", "grand"… for a subtotal line; nil for an ordinary value.
    public var itemType: String?
    public var hidden: Bool
    public init(index: Int? = nil, itemType: String? = nil, hidden: Bool = false) {
        self.index = index; self.itemType = itemType; self.hidden = hidden
    }
    public static let subtotal = PivotFieldItem(itemType: "default")
}

/// A value summarised in the body of a pivot table (`<dataField>`).
public struct PivotDataField: Hashable, Sendable {
    /// How the values are summarised. The names are the file format's own.
    public enum Function: String, Hashable, Sendable, CaseIterable {
        case sum, count, average, max, min, product, countNums, stdDev, stdDevp, `var`, varp

        /// The word Excel puts in the caption ("合計 / Sum").
        public var caption: String {
            switch self {
            case .sum: "Sum"; case .count: "Count"; case .average: "Average"; case .max: "Max"; case .min: "Min"
            case .product: "Product"; case .countNums: "Count Numbers"; case .stdDev: "StdDev"
            case .stdDevp: "StdDevp"; case .var: "Var"; case .varp: "Varp"
            }
        }
    }
    /// The caption shown over the column.
    public var name: String?
    /// Index into `PivotTable.fields`.
    public var field: Int
    public var function: Function
    public var numberFormatID: Int?
    /// "percentOfTotal", "difference", "runTotal"… — shown relative to another field rather than plainly.
    public var showDataAs: String?
    public var baseField: Int?
    public var baseItem: Int?

    public init(field: Int, function: Function = .sum, name: String? = nil, numberFormatID: Int? = nil,
                showDataAs: String? = nil, baseField: Int? = nil, baseItem: Int? = nil) {
        self.field = field; self.function = function; self.name = name; self.numberFormatID = numberFormatID
        self.showDataAs = showDataAs; self.baseField = baseField; self.baseItem = baseItem
    }
}

/// A report filter above a pivot table (`<pageField>`).
public struct PivotPageField: Hashable, Sendable {
    /// Index into `PivotTable.fields`.
    public var field: Int
    /// Which of the field's items is selected; nil is "(All)".
    public var item: Int?
    public var name: String?
    public init(field: Int, item: Int? = nil, name: String? = nil) {
        self.field = field; self.item = item; self.name = name
    }
}

/// The built-in look of a pivot table (`<pivotTableStyleInfo>`).
public struct PivotStyleInfo: Hashable, Sendable {
    public var name: String?
    public var showRowHeaders: Bool
    public var showColumnHeaders: Bool
    public var showRowStripes: Bool
    public var showColumnStripes: Bool
    public var showLastColumn: Bool

    public init(name: String? = nil, showRowHeaders: Bool = true, showColumnHeaders: Bool = true,
                showRowStripes: Bool = false, showColumnStripes: Bool = false, showLastColumn: Bool = true) {
        self.name = name; self.showRowHeaders = showRowHeaders; self.showColumnHeaders = showColumnHeaders
        self.showRowStripes = showRowStripes; self.showColumnStripes = showColumnStripes
        self.showLastColumn = showLastColumn
    }
    public static let `default` = PivotStyleInfo(name: "PivotStyleLight16")
}

/// The snapshot of a source range a pivot table reads (`xl/pivotCache/pivotCacheDefinition*.xml`).
///
/// SwiftSheets does not write the cached rows themselves: `refreshOnLoad` is set instead, so the application reads
/// the source range when it opens the file. A cache read from a file keeps whatever record part it came with.
public struct PivotCache: Hashable, Sendable {
    /// The cells the pivot summarises, header row included.
    public var sourceRef: CellRange
    /// The sheet those cells are on.
    public var sourceSheet: String
    /// A defined name or table name used instead of a reference.
    public var sourceName: String?
    /// One per column of the source, in order.
    public var fields: [PivotCacheField]
    /// Read the source range again when the file is opened. SwiftSheets sets this on every cache it writes.
    public var refreshOnLoad: Bool
    /// How many source rows the cache holds, when it holds any.
    public var recordCount: Int?
    /// Who last refreshed the cache, and when — informational.
    public var refreshedBy: String?

    package var otherAttributes: [String: String] = [:]
    package var fragments: [XMLFragment] = []
    package var definitionPath: String?
    package var recordsPath: String?
    package var relationshipId: String?
    package var cacheId: Int?
    /// The `pivotCacheRecords` part as the file had it, re-packed unchanged.
    package var recordsXML: Data?

    public init(sourceRef: CellRange, sourceSheet: String, fields: [PivotCacheField],
                sourceName: String? = nil, refreshOnLoad: Bool = true, recordCount: Int? = nil) {
        self.sourceRef = sourceRef; self.sourceSheet = sourceSheet; self.fields = fields
        self.sourceName = sourceName; self.refreshOnLoad = refreshOnLoad; self.recordCount = recordCount
    }
}

/// One column of a pivot cache (`<cacheField>`): its name, and the distinct values found in it.
public struct PivotCacheField: Hashable, Sendable {
    public var name: String
    public var numberFormatID: Int?
    /// The distinct values of the column, in the order a `PivotFieldItem.index` counts them. Empty is allowed and
    /// is what SwiftSheets writes for a cache the application will refresh.
    public var sharedItems: [PivotItem]
    /// What kinds the column holds, as the file declares them (`<sharedItems containsString containsNumber …>`).
    /// Carried verbatim; Excel recomputes them on refresh.
    package var sharedItemAttributes: [String: String] = [:]

    public init(name: String, numberFormatID: Int? = nil, sharedItems: [PivotItem] = []) {
        self.name = name; self.numberFormatID = numberFormatID; self.sharedItems = sharedItems
    }
}

/// One distinct value in a pivot cache field.
public enum PivotItem: Hashable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(CivilDateTime)
    case error(String)
    /// A blank source cell.
    case missing
}
