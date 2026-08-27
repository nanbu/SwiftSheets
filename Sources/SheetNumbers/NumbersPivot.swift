import Foundation
import SheetCore

/// Pivot tables in Numbers (spec Appendix B.19).
///
/// A Numbers pivot is **one table info holding two table models**: `tableModel` is the summary the reader sees,
/// `pivot_data_model` is a copy of the source rows that lives nowhere on a sheet, and `is_a_pivot_table` says the
/// pair is a pivot. The rules live on a `TST.PivotOwnerArchive` that names source columns by **column UID**, and
/// what groups exist lives in `TST.GroupByArchive` trees hung off each model's category owner.
///
/// The layout of all of it was read off documents Numbers itself wrote: a workbook with seventeen pivots, one per
/// function and one per shape, imported and saved again. What that measurement settled, and what it did not:
///
/// * **The group tree has to be there, and its shape is what counts.** A node per distinct value, each naming the
///   source rows that fall into it. Numbers does not grow nodes that are missing — a tree pruned to its root shows
///   one group, and a pivot with no tree at all opens as an error.
/// * **The cached aggregation is not optional.** A document with the group-bys' `aggregator` archives removed
///   opens with every summary cell at zero, twice over on a settled reading (re-measured under a faked old
///   version on 2026-08-27). Numbers renders what the cache holds; it does not sum the source afresh.
/// * **Not established:** whether Numbers re-derives a node's *label* from its rows. The one reading that looked
///   like proof — a tree with a deliberately wrong label coming back right — is confounded: the summary's own
///   stored cells carry the labels too, and a pruned tree was shown to display them from there.
enum NumbersPivot {

    // MARK: - The numbers Apple left unnamed

    /// `TST.ColumnAggregateArchive.agg_type` per summary function, **observed**: one sheet per function was written
    /// as `.xlsx`, imported by Numbers 15.3.1 and saved back, and each archive matched to the sheet that made it
    /// (Appendix B.19). All eleven of the model's functions have a counterpart, so nothing falls back here.
    static func aggType(_ f: PivotDataField.Function) -> Int {
        switch f {
        case .count: 1
        case .sum: 2
        case .min: 4
        case .max: 5
        case .countNums: 13
        case .average: 18
        case .product: 21
        case .stdDev: 26
        case .stdDevp: 28
        case .var: 30
        case .varp: 32
        }
    }

    /// `TST.TableModelArchive.pivot_value_types_by_col`, one per source column: 3 where the column is grouped by,
    /// 2 where it is summarised. Observed on the same documents.
    static let valueTypeGrouping = 3
    static let valueTypeAggregate = 2

    // MARK: - What the source says

    /// One column of the source range: its heading, and the value in each row under it.
    struct SourceColumn {
        var name: String
        var values: [CellValue?]
    }

    /// The source range read out of the workbook, header row separated from the rows under it. Nil when the sheet
    /// or the range is not there to read — the caller says so and drops the pivot rather than writing half of one.
    static func source(of pivot: PivotTable, in workbook: Workbook) -> [SourceColumn]? {
        guard let sheet = workbook.sheets[pivot.cache.sourceSheet] else { return nil }
        let ref = pivot.cache.sourceRef
        guard ref.maxRow > ref.minRow else { return nil }          // a header row and nothing under it is not a source
        var columns: [SourceColumn] = []
        for col in ref.minCol...ref.maxCol {
            let heading = sheet[CellRef(row: ref.minRow, col: col)]?.stringValue ?? ""
            var values: [CellValue?] = []
            for row in (ref.minRow + 1)...ref.maxRow { values.append(sheet[CellRef(row: row, col: col)]) }
            columns.append(SourceColumn(name: heading, values: values))
        }
        return columns
    }

    // MARK: - Grouping

    /// One node of a group tree: the value it stands for, the source rows that fall into it, and the nodes under it.
    ///
    /// The row numbers are counted as the **copy of the source** counts them — its header is row 0, so the first
    /// data row is 1. That is how Numbers writes them.
    struct GroupNode {
        var value: CellValue?
        var rows: [Int]
        var children: [GroupNode] = []
        /// The value path from the root down to this node — what identifies the node across every tree of the
        /// same pivot. Numbers derives a node's UUID from this path (the same values give the same UUID in every
        /// document); this writer cannot reproduce the derivation, but it does not have to: a specimen whose nine
        /// node UUIDs were replaced with fresh randoms, **consistently everywhere they appear**, draws in full
        /// (measured 2026-08-27). Consistency is the contract, and `uid(for:)` below is how it is kept.
        var path: [String]
        var uid: ProtoMessage
    }

    /// One shared UUID per value path, so that every tree of the pivot — the full grouping and each of the
    /// column-prefix groupings — names a node the same way the order map, the lane maps and the aggregate
    /// formulas do.
    struct PathUIDs {
        private var store: [String: ProtoMessage] = [:]
        static func key(_ path: [String]) -> String { path.joined(separator: "\u{1F}") }
        mutating func uid(for path: [String]) -> ProtoMessage {
            let k = Self.key(path)
            if let existing = store[k] { return existing }
            let fresh = NumbersUUID.random().uuid
            store[k] = fresh
            return fresh
        }
        func uid(forKey key: String) -> ProtoMessage? { store[key] }
    }

    /// The source rows grouped by `columns` in turn, outermost first. Values are ordered as Numbers orders them on
    /// screen: ascending, text by its own comparison, numbers numerically.
    static func group(_ rows: [Int], by columns: [SourceColumn], from level: Int = 0,
                      path: [String] = [], uids: inout PathUIDs) -> [GroupNode] {
        guard level < columns.count else { return [] }
        let column = columns[level]
        var order: [String] = []
        var byKey: [String: (value: CellValue?, rows: [Int])] = [:]
        for row in rows {
            let value = column.values.indices.contains(row - 1) ? column.values[row - 1] : nil
            let key = value?.stringValue ?? ""
            if byKey[key] == nil { byKey[key] = (value, []); order.append(key) }
            byKey[key]!.rows.append(row)
        }
        order.sort { a, b in
            if let x = byKey[a]?.value?.doubleValue, let y = byKey[b]?.value?.doubleValue { return x < y }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return order.map { key in
            let entry = byKey[key]!
            let nodePath = path + [key]
            return GroupNode(value: entry.value, rows: entry.rows,
                             children: group(entry.rows, by: columns, from: level + 1, path: nodePath, uids: &uids),
                             path: nodePath, uid: uids.uid(for: nodePath))
        }
    }

    /// Every node of a tree, children before their parent — the order both axes are displayed in: a group's
    /// members first, then the group's own subtotal lane (read off the view maps of every multi-level document
    /// Numbers wrote).
    static func postorder(_ nodes: [GroupNode]) -> [GroupNode] {
        var out: [GroupNode] = []
        func walk(_ n: GroupNode) { n.children.forEach(walk); out.append(n) }
        nodes.forEach(walk)
        return out
    }

    // MARK: - Summarising

    /// `function` over the values of `column` in `rows`. Nil where the function has nothing to work on — an
    /// average of no numbers is not zero.
    static func summarise(_ rows: [Int], of column: SourceColumn, by function: PivotDataField.Function) -> Double? {
        var numbers: [Double] = []
        var nonEmpty = 0
        for row in rows {
            guard column.values.indices.contains(row - 1), let value = column.values[row - 1] else { continue }
            nonEmpty += 1
            if let d = value.doubleValue { numbers.append(d) }
        }
        switch function {
        case .count: return Double(nonEmpty)
        case .countNums: return Double(numbers.count)
        default: break
        }
        guard !numbers.isEmpty else { return nil }
        switch function {
        case .sum: return numbers.reduce(0, +)
        case .average: return numbers.reduce(0, +) / Double(numbers.count)
        case .max: return numbers.max()
        case .min: return numbers.min()
        case .product: return numbers.reduce(1, *)
        case .stdDev, .var, .stdDevp, .varp:
            let mean = numbers.reduce(0, +) / Double(numbers.count)
            let squares = numbers.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            let sample = function == .stdDev || function == .var
            if sample && numbers.count < 2 { return nil }
            let variance = squares / Double(sample ? numbers.count - 1 : numbers.count)
            return (function == .stdDev || function == .stdDevp) ? variance.squareRoot() : variance
        case .count, .countNums: return nil   // answered above
        }
    }

    // MARK: - The summary as a table

    /// One cell of the summary model's store, in **displayed** coordinates — the grid's lanes with the subtotal
    /// lanes interleaved (each group's own lane right after its members) and the grand-total lanes last.
    struct SummaryCell {
        var row: Int; var col: Int
        var value: CellValue
        var formula: FormulaSpec?
    }

    /// What a total-lane cell's `CATEGORY_REF` names, before the UUIDs exist to name it with. The one law that
    /// covers every cell of every measured document (seven grounds, Appendix B.28): a cell at row depth `r`
    /// (0 = the grand-total row) and column depth `c` (0 = the grand-total column) references the group-by that
    /// walks the first `c` column fields plus every row field, at level `c + r`, at the node whose path is the
    /// column path followed by the row path.
    struct FormulaSpec {
        /// Which grouping: 0 = the full one (kind 205), `columnFields.count` = the row grouping.
        var gbOffset: Int
        var level: Int
        /// `PathUIDs.key` of the node, or nil for the root sentinel.
        var pathKey: String?
        /// Index into `dataFields` — names the summarised column.
        var field: Int
    }

    /// The whole shape of one pivot, laid out the way Numbers lays it out. The stored grid holds the header
    /// lanes and the leaf lanes only; everything a total lane holds goes to the summary model, at displayed
    /// coordinates. Numbers rebuilds the display from the rules when it opens the document, so the grid is what
    /// every *other* reader shows, and what the model reads back.
    struct Layout {
        var table: Table
        var headerRows = 0
        var headerColumns = 0
        /// The grid's lane UUIDs (header lanes + leaf lanes), grid order.
        var gridRowUIDs: [ProtoMessage] = []
        var gridColumnUIDs: [ProtoMessage] = []
        /// Every displayed lane's UUID: header lanes, then postorder node lanes, then the grand-total lanes.
        var displayRowUIDs: [ProtoMessage] = []
        var displayColumnUIDs: [ProtoMessage] = []
        /// The axes of `pivot_order`: postorder node UUIDs plus the sentinel — no header lanes, no per-value
        /// repetition.
        var orderRowUIDs: [ProtoMessage] = []
        var orderColumnUIDs: [ProtoMessage] = []
        /// The summary model's cells.
        var cells: [SummaryCell] = []
        /// One per row field: the UUID of its label column, which is also the field's `grouping_column_uid` on
        /// the rules and the group-bys (Appendix B.19: those have to be the same value).
        var rowGroupingUIDs: [ProtoMessage] = []
        /// One per column field: the UUID of its heading row, likewise.
        var columnGroupingUIDs: [ProtoMessage] = []
        var totalRowLane = false
        var totalColumnLane = false
    }

    /// The caption lane's UUID. Not random: Numbers writes the ASCII bytes "aggre names row" for the heading row
    /// the value captions sit in, and "aggre names col" for the label column of a pivot with no row fields
    /// (read off every measured document).
    static var captionRowUID: ProtoMessage {
        var s = ProtoMessage(typeName: "TSP.UUID")
        s.set("lower", uint: 0x616e_2065_7267_6761); s.set("upper", uint: 0x0077_6f72_2073_656d)
        return s
    }
    static var captionColumnUID: ProtoMessage {
        var s = ProtoMessage(typeName: "TSP.UUID")
        s.set("lower", uint: 0x616e_2065_7267_6761); s.set("upper", uint: 0x006c_6f63_2073_656d)
        return s
    }

    static func layout(_ pivot: PivotTable, source: [SourceColumn], named name: String,
                       rowFields: [Int], columnFields: [Int], dataFields: [PivotDataField],
                       rowTree: [GroupNode], columnTree: [GroupNode], allRows: [Int]) -> Layout {
        var out = Layout(table: Table(name: name))
        let V = dataFields.count
        // Values live on the axis that has room for a lane per value: the columns, unless only the columns are
        // grouped â then the captions run down the label column and the value lanes are rows (measured: a
        // columns-only pivot draws its caption in the label column of its one body row).
        let valuesOnColumns = !rowFields.isEmpty || columnFields.isEmpty
        let columnFactor = valuesOnColumns ? V : 1
        let rowFactor = valuesOnColumns ? 1 : V
        out.headerRows = columnFields.count + (rowFields.isEmpty ? 0 : 1)
        out.headerColumns = Swift.max(1, rowFields.count)
        out.rowGroupingUIDs = rowFields.map { _ in NumbersUUID.random().uuid }
        out.columnGroupingUIDs = columnFields.map { _ in NumbersUUID.random().uuid }
        out.totalRowLane = !rowFields.isEmpty
        out.totalColumnLane = !columnFields.isEmpty

        let postR = postorder(rowTree)
        let postC = postorder(columnTree)
        let rowLeaves = postR.filter(\.children.isEmpty)
        let columnLeaves = postC.filter(\.children.isEmpty)
        func caption(_ d: Int) -> String {
            dataFields[d].name ?? "\(source[dataFields[d].field].name)ï¼\(dataFields[d].function.caption)ï¼"
        }
        var nodeByKey: [String: GroupNode] = [:]
        for n in postR + postC { nodeByKey[PathUIDs.key(n.path)] = n }
        func label(_ path: [String]) -> CellValue { nodeByKey[PathUIDs.key(path)]?.value ?? .text(path.last ?? "") }

        // Which of its ancestors’ labels a leaf draws: the depth-ℓ label goes on the first leaf of the
        // depth-ℓ ancestor’s span, so `flags[ℓ]` is whether every step below ℓ on this leaf’s path is a
        // first child (measured: `East` on its first row only, `A` / `B` on every row).
        func firstLeafFlags(_ nodes: [GroupNode]) -> [String: [Bool]] {
            var out: [String: [Bool]] = [:]
            func walk(_ n: GroupNode, firstStack: [Bool]) {
                if n.children.isEmpty {
                    let depth = firstStack.count
                    // flags[0] unused; flags[ℓ] for ℓ = 1…depth
                    var flags = [false]
                    for l in 1...depth { flags.append((l..<depth).allSatisfy { firstStack[$0] }) }
                    out[PathUIDs.key(n.path)] = flags
                    return
                }
                for (i, c) in n.children.enumerated() { walk(c, firstStack: firstStack + [i == 0]) }
            }
            for (i, n) in nodes.enumerated() { walk(n, firstStack: [i == 0]) }
            return out
        }
        let rowLeafFlags = firstLeafFlags(rowTree)
        let columnLeafFlags = firstLeafFlags(columnTree)

        // ---- the stored grid ----
        // heading rows, one per column field: the field’s name in the last label column, each depth-(ℓ+1)
        // ancestor’s label on the first lane of its span
        for l in columnFields.indices {
            out.table[l, out.headerColumns - 1] = .text(source[columnFields[l]].name)
            for (i, leaf) in columnLeaves.enumerated() where columnLeafFlags[PathUIDs.key(leaf.path)]?[l + 1] == true {
                out.table[l, out.headerColumns + i * columnFactor] = label(Array(leaf.path.prefix(l + 1)))
            }
        }
        // the caption row, when there are row fields: the row fields’ names over their label columns, and the
        // value captions — every value lane when there are several values, the first lane alone when one
        // (measured: `Region,Qty（合計）,,` against `Region,Qty（合計）,Price（合計）,Qty（合計）,…`)
        if !rowFields.isEmpty {
            let cr = columnFields.count
            for l in rowFields.indices { out.table[cr, l] = .text(source[rowFields[l]].name) }
            if columnFields.isEmpty {
                for d in 0..<V { out.table[cr, out.headerColumns + d] = .text(caption(d)) }
            } else if V > 1 {
                for i in columnLeaves.indices {
                    for d in 0..<V { out.table[cr, out.headerColumns + i * V + d] = .text(caption(d)) }
                }
            } else {
                out.table[cr, out.headerColumns] = .text(caption(0))
            }
        }
        // body cells
        func intersect(_ a: [Int], _ b: [Int]) -> [Int] {
            let allowed = Set(b)
            return a.filter { allowed.contains($0) }
        }
        func bodyValue(rowRows: [Int], columnRows: [Int], field d: Int) -> CellValue? {
            summarise(intersect(rowRows, columnRows), of: source[dataFields[d].field], by: dataFields[d].function)
                .map { CellValue(Decimal($0)) }
        }
        if rowFields.isEmpty {
            // one body row per value (or the one row), captioned in the label column
            for r in 0..<rowFactor {
                out.table[out.headerRows + r, 0] = .text(caption(valuesOnColumns ? 0 : r))
                for (i, leaf) in (columnFields.isEmpty ? [] : columnLeaves).enumerated() {
                    for d in 0..<columnFactor {
                        out.table[out.headerRows + r, out.headerColumns + i * columnFactor + d] =
                            bodyValue(rowRows: allRows, columnRows: leaf.rows, field: valuesOnColumns ? d : r)
                    }
                }
            }
        } else {
            for (r, leaf) in rowLeaves.enumerated() {
                for l in rowFields.indices where rowLeafFlags[PathUIDs.key(leaf.path)]?[l + 1] == true {
                    out.table[out.headerRows + r, l] = label(Array(leaf.path.prefix(l + 1)))
                }
                let columnSets: [[Int]] = columnFields.isEmpty ? [allRows] : columnLeaves.map(\.rows)
                for (i, set) in columnSets.enumerated() {
                    for d in 0..<V {
                        out.table[out.headerRows + r, out.headerColumns + i * V + d] =
                            bodyValue(rowRows: leaf.rows, columnRows: set, field: d)
                    }
                }
            }
        }

        // ---- the lane UUIDs ----
        let sentinel = axisSentinel
        out.gridRowUIDs = out.columnGroupingUIDs + (rowFields.isEmpty ? [] : [captionRowUID])
        out.gridRowUIDs += rowFields.isEmpty ? Array(repeating: sentinel, count: rowFactor) : rowLeaves.map(\.uid)
        out.gridColumnUIDs = rowFields.isEmpty ? [captionColumnUID] : out.rowGroupingUIDs
        out.gridColumnUIDs += columnFields.isEmpty ? Array(repeating: sentinel, count: columnFactor)
                                                   : columnLeaves.flatMap { Array(repeating: $0.uid, count: columnFactor) }
        out.displayRowUIDs = out.columnGroupingUIDs + (rowFields.isEmpty ? [] : [captionRowUID])
        out.displayRowUIDs += rowFields.isEmpty ? Array(repeating: sentinel, count: rowFactor) : postR.map(\.uid)
        if out.totalRowLane { out.displayRowUIDs.append(sentinel) }
        out.displayColumnUIDs = rowFields.isEmpty ? [captionColumnUID] : out.rowGroupingUIDs
        out.displayColumnUIDs += columnFields.isEmpty ? Array(repeating: sentinel, count: columnFactor)
                                                      : postC.flatMap { Array(repeating: $0.uid, count: columnFactor) }
        if out.totalColumnLane { out.displayColumnUIDs += Array(repeating: sentinel, count: columnFactor) }
        out.orderRowUIDs = postR.map(\.uid) + [sentinel]
        out.orderColumnUIDs = postC.map(\.uid) + [sentinel]

        // ---- the summary model’s cells ----
        // A lane on either axis is the grid’s (a leaf, or the header) or the summary’s (a group’s own subtotal
        // lane, or the grand-total lane). Every cell that touches a summary lane is written here, at displayed
        // coordinates; the grand-total lanes’ cells only when the pivot shows them.
        struct Lane { var index: Int; var rows: [Int]; var depth: Int; var path: [String]; var isSummary: Bool; var isGrand: Bool; var value: Int }
        var rowLanes: [Lane] = []
        if rowFields.isEmpty {
            for r in 0..<rowFactor {
                rowLanes.append(Lane(index: out.headerRows + r, rows: allRows, depth: 0, path: [], isSummary: false, isGrand: false, value: r))
            }
        } else {
            for (p, node) in postR.enumerated() {
                rowLanes.append(Lane(index: out.headerRows + p, rows: node.rows, depth: node.path.count,
                                     path: node.path, isSummary: !node.children.isEmpty, isGrand: false, value: 0))
            }
            rowLanes.append(Lane(index: out.headerRows + postR.count, rows: allRows, depth: 0, path: [],
                                 isSummary: true, isGrand: true, value: 0))
        }
        var colLanes: [Lane] = []
        if columnFields.isEmpty {
            for d in 0..<columnFactor {
                colLanes.append(Lane(index: out.headerColumns + d, rows: allRows, depth: 0, path: [], isSummary: false, isGrand: false, value: d))
            }
        } else {
            for (p, node) in postC.enumerated() {
                for d in 0..<columnFactor {
                    colLanes.append(Lane(index: out.headerColumns + p * columnFactor + d, rows: node.rows,
                                         depth: node.path.count, path: node.path,
                                         isSummary: !node.children.isEmpty, isGrand: false, value: d))
                }
            }
            for d in 0..<columnFactor {
                colLanes.append(Lane(index: out.headerColumns + postC.count * columnFactor + d, rows: allRows,
                                     depth: 0, path: [], isSummary: true, isGrand: true, value: d))
            }
        }
        let showGrandRow = pivot.showRowGrandTotals
        let showGrandColumn = pivot.showColumnGrandTotals
        func hidden(_ lane: Lane, isRow: Bool) -> Bool { lane.isGrand && !(isRow ? showGrandRow : showGrandColumn) }

        // labels over the summary column lanes: a subtotal column repeats its group’s label in the heading row
        // of its depth, the grand-total lane says 総計 in the first — on the first value lane only — and every
        // summary lane gets its caption when several values share the axis
        for lane in colLanes where lane.isSummary && !hidden(lane, isRow: false) {
            if lane.value == 0 {
                out.cells.append(SummaryCell(row: lane.path.isEmpty ? 0 : lane.path.count - 1, col: lane.index,
                                             value: lane.path.isEmpty ? .text("総計") : label(lane.path)))
            }
            if !rowFields.isEmpty, V > 1 {
                out.cells.append(SummaryCell(row: columnFields.count, col: lane.index, value: .text(caption(lane.value))))
            }
        }
        // labels beside the summary row lanes: the group’s bare label in the label column of its depth,
        // 総計 in the first for the grand-total row
        for lane in rowLanes where lane.isSummary && !hidden(lane, isRow: true) {
            out.cells.append(SummaryCell(row: lane.index, col: lane.path.isEmpty ? 0 : lane.path.count - 1,
                                         value: lane.path.isEmpty ? .text("総計") : label(lane.path)))
        }
        // the values: every lane pair at least one side of which is the summary’s
        func addValueCell(rowLane: Lane, colLane: Lane) {
            guard !hidden(rowLane, isRow: true), !hidden(colLane, isRow: false) else { return }
            let field = valuesOnColumns ? colLane.value : rowLane.value
            guard let v = bodyValue(rowRows: rowLane.rows, columnRows: colLane.rows, field: field) else { return }
            let path = colLane.path + rowLane.path
            out.cells.append(SummaryCell(row: rowLane.index, col: colLane.index, value: v,
                                         formula: FormulaSpec(gbOffset: columnFields.count - colLane.depth,
                                                              level: colLane.depth + rowLane.depth,
                                                              pathKey: path.isEmpty ? nil : PathUIDs.key(path),
                                                              field: field)))
        }
        for rowLane in rowLanes where rowLane.isSummary {
            for colLane in colLanes { addValueCell(rowLane: rowLane, colLane: colLane) }
        }
        for colLane in colLanes where colLane.isSummary {
            for rowLane in rowLanes where !rowLane.isSummary { addValueCell(rowLane: rowLane, colLane: colLane) }
        }
        return out
    }

    // MARK: - Archives

    /// The map a pivot orders itself by: the outermost group node of each axis, in the order the summary draws
    /// them, and the sentinel `(1, 0)` Numbers keeps at the end of both lists (Appendix B.19).
    /// The UUID that stands for a pivot's label lane — the column of row headings and the row of column headings,
    /// which belong to no group. Its place in the axis is **last** (measured off the reference's index arrays;
    /// the raw `sorted_` list shows it first only because zeroes sort first).
    static var axisSentinel: ProtoMessage {
        var s = ProtoMessage(typeName: "TSP.UUID"); s.set("lower", int: 1); s.set("upper", int: 0)
        return s
    }

    /// A `TST.ColumnRowUIDMapArchive` from UID lists given **in their real order** (grid order for a table,
    /// axis order for the pivot's order map).
    ///
    /// The stored lists are **sorted by UUID** — Numbers resolves a UID by binary search, so an unsorted list is
    /// a lookup that silently fails — and the two index arrays carry the permutation: `index_for_uid[sortedPos]`
    /// is the real position of that UID, `uid_for_index[realPos]` is where in the sorted list it sits. Read off
    /// the reference document's arrays (Appendix B.19).
    static func uidMap(columns: [ProtoMessage], rows: [ProtoMessage]) -> ProtoMessage {
        func key(_ uuid: ProtoMessage) -> (UInt64, UInt64) {
            ((uuid.uint("upper") ?? 0), (uuid.uint("lower") ?? 0))
        }
        func permute(_ uids: [ProtoMessage]) -> (sorted: [ProtoMessage], indexForUID: [Int], uidForIndex: [Int]) {
            let order = uids.indices.sorted { key(uids[$0]) < key(uids[$1]) }
            var uidForIndex = [Int](repeating: 0, count: uids.count)
            for (sortedPos, real) in order.enumerated() { uidForIndex[real] = sortedPos }
            return (order.map { uids[$0] }, order, uidForIndex)
        }
        let c = permute(columns), r = permute(rows)
        var m = ProtoMessage(typeName: "TST.ColumnRowUIDMapArchive")
        m.set("sorted_column_uids", messages: c.sorted)
        m.set("column_index_for_uid", ints: c.indexForUID)
        m.set("column_uid_for_index", ints: c.uidForIndex)
        m.set("sorted_row_uids", messages: r.sorted)
        m.set("row_index_for_uid", ints: r.indexForUID)
        m.set("row_uid_for_index", ints: r.uidForIndex)
        return m
    }

    /// The pivot's order map: each axis is the outermost group nodes in tree order, then the label-lane sentinel.
    static func orderMap(columns: [ProtoMessage], rows: [ProtoMessage]) -> ProtoMessage {
        uidMap(columns: columns + [axisSentinel], rows: rows + [axisSentinel])
    }

    /// A `TSP.UUID` per source column, and the map the source copy carries so the rules can name a column by it.
    static func columnUIDMap(count: Int, rowCount: Int) -> (map: ProtoMessage, columns: [ProtoMessage], rows: [ProtoMessage]) {
        let columns = (0..<count).map { _ in NumbersUUID.random().uuid }
        let rows = (0..<rowCount).map { _ in NumbersUUID.random().uuid }
        return (uidMap(columns: columns, rows: rows), columns, rows)
    }

    /// A set of row numbers as Numbers spells one: **runs**, not rows. Consecutive numbers become a single entry
    /// carrying where the run begins and where it ends; a number standing on its own carries only its beginning.
    ///
    /// It matters at the root, which covers every row of the source: Numbers writes that as one `1…8`, and a
    /// document that instead lists row 1 alone is a document whose pivot Numbers draws with no groups in it at all
    /// — the summary comes up as two empty headings (Appendix B.19).
    static func rowSet(_ rows: [Int]) -> ProtoMessage {
        var set = ProtoMessage(typeName: "TSCE.IndexSetArchive")
        var entries: [ProtoMessage] = []
        var i = 0
        let sorted = rows.sorted()
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            var e = ProtoMessage(typeName: "TSCE.IndexSetArchive.IndexSetEntry")
            e.set("range_begin", int: sorted[i])
            if j > i { e.set("range_end", int: sorted[j]) }
            entries.append(e)
            i = j + 1
        }
        set.set("entries", messages: entries)
        return set
    }

    /// The format struct every cell value inside a group tree carries. 260 is what Numbers writes for both the
    /// text and the number kinds in the documents this was read from.
    static func plainFormat() -> ProtoMessage {
        var f = ProtoMessage(typeName: "TSK.FormatStructArchive")
        f.set("format_type", int: 260)
        return f
    }

    /// One `group_cell_value` / `format_manager.cell_value`: the value the node stands for.
    static func cellValue(_ value: CellValue?) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TSCE.CellValueArchive")
        func number(_ d: Double) {
            m.set("cell_value_type", int: 4)                  // NUMBER_TYPE
            var n = ProtoMessage(typeName: "TSCE.NumberCellValueArchive")
            n.set("value", double: d); n.set("format", message: plainFormat())
            m.set("number_value", message: n)
        }
        switch value {
        case .integer(let i)?: number(Double(i))
        case .number(let d)?: number((d as NSDecimalNumber).doubleValue)
        default:
            m.set("cell_value_type", int: 5)                  // STRING_TYPE
            var s = ProtoMessage(typeName: "TSCE.StringCellValueArchive")
            s.set("value", string: value?.stringValue ?? "")
            s.set("format", message: plainFormat())
            // Numbers writes these out even when they are false; a group node whose value omits them is one it
            // will not render (Appendix B.19)
            s.set("format_is_explicit", bool: false)
            s.set("is_regex", bool: false)
            s.set("is_case_sensitive_regex", bool: false)
            m.set("string_value", message: s)
        }
        return m
    }

    /// Every node's slot in the group-by's formula coordinate space, children before their parent. Numbers keeps
    /// slots 0…7 for its own bookkeeping; with several summarised values the space repeats as one block per value
    /// (measured: a two-value document's nodes carry two `agg_formula_coords`, one into each block, and each
    /// aggregator's tree uses its own block).
    static func slotMap(_ nodes: [GroupNode]) -> (slots: [String: Int], count: Int) {
        var slots: [String: Int] = [:]
        var next = 0
        func walk(_ n: GroupNode) {
            n.children.forEach(walk)
            slots[PathUIDs.key(n.path)] = next; next += 1
        }
        nodes.forEach(walk)
        return (slots, next + 1)              // + the root's slot, last
    }
    static func coordinate(slot: Int, block: Int, blockSize: Int) -> ProtoMessage {
        var coord = ProtoMessage(typeName: "TSCE.CellCoordinateArchive")
        coord.set("column", int: 8 + block * blockSize + slot); coord.set("row", int: 0)
        return coord
    }

    /// One node of the tree Numbers reads to know what groups there are, with one formula coordinate per
    /// summarised value.
    static func groupNode(_ node: GroupNode, slots: [String: Int], blockSize: Int, valueCount: Int) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive")
        m.set("group_uid", message: node.uid)
        let children = node.children.map { groupNode($0, slots: slots, blockSize: blockSize, valueCount: valueCount) }
        let slot = slots[PathUIDs.key(node.path)] ?? 0
        m.set("agg_formula_coords", messages: (0..<valueCount).map { coordinate(slot: slot, block: $0, blockSize: blockSize) })
        let value = cellValue(node.value)
        m.set("group_cell_value", message: value)
        var manager = ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive.FormatManagerArchive")
        manager.set("cell_value", message: value)
        manager.set("formats", messages: [plainFormat()])
        manager.set("row_uid_lookup_sets", messages: [rowSet(node.rows)])
        m.set("format_manager", message: manager)
        m.set("row_indexes", message: rowSet(node.rows))
        m.set("row_lookup_uids", message: rowSet(node.rows))
        if !children.isEmpty { m.set("child", messages: children) }
        return m
    }

    // MARK: - The cached summing

    /// The number Numbers writes into an accumulator's cell values. Not `plainFormat`'s 260: the accumulators of a
    /// document Numbers wrote carry 256 with `decimal_places` 253, which is what "no explicit format" looks like
    /// on a number that came out of a calculation rather than out of a cell.
    static func accumulatorFormat() -> ProtoMessage {
        var f = ProtoMessage(typeName: "TSK.FormatStructArchive")
        f.set("format_type", int: 256)
        f.set("decimal_places", int: 253)
        f.set("negative_style", int: 0)
        f.set("show_thousands_separator", bool: false)
        return f
    }

    /// A number as an accumulator states one: the double **and** its decimal128 spelling, which is the one Numbers
    /// reads back when it draws the cell.
    static func accumulatorNumber(_ value: Double) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TSCE.CellValueArchive")
        m.set("cell_value_type", int: 4)
        var n = ProtoMessage(typeName: "TSCE.NumberCellValueArchive")
        n.set("value", double: value)
        n.set("unit_index", int: 0)
        n.set("format", message: accumulatorFormat())
        n.set("format_is_explicit", bool: false)
        let bytes = CellStorage.encodeDecimal128(Decimal(value))
        n.set("decimal_low", uint: littleEndian(bytes[0..<8]))
        n.set("decimal_high", uint: littleEndian(bytes[8..<16]))
        m.set("number_value", message: n)
        return m
    }

    static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * i) }
        return v
    }

    /// What a node of the aggregator tree remembers about the rows under it.
    ///
    /// Numbers **draws what this holds**; it does not add the source up again when it opens the document. A pivot
    /// written without these opens with every summary cell at zero — measured twice on a settled reading
    /// (Appendix B.19). Only the fields a document Numbers wrote carries are written: the counts and extremes of
    /// the numbers seen, their total, and their product.
    static func accumulator(_ rows: [Int], of column: SourceColumn) -> ProtoMessage {
        var numbers: [Double] = []
        for row in rows {
            guard column.values.indices.contains(row - 1), let value = column.values[row - 1] else { continue }
            switch value {
            case .integer(let i): numbers.append(Double(i))
            case .number(let d): numbers.append((d as NSDecimalNumber).doubleValue)
            case .bool(let b): numbers.append(b ? 1 : 0)
            default: continue
            }
        }
        var m = ProtoMessage(typeName: "TST.AccumulatorArchive")
        m.set("number_count", int: numbers.count)
        guard !numbers.isEmpty else { return m }
        let total = numbers.reduce(0, +)
        m.set("min_value", message: accumulatorNumber(numbers.min()!))
        m.set("max_value", message: accumulatorNumber(numbers.max()!))
        m.set("number_total_value", message: accumulatorNumber(total))
        m.set("secs_to_add", double: total)
        m.set("product_value", message: accumulatorNumber(numbers.reduce(1, *)))
        return m
    }

    /// One node of the aggregator tree, walked in exactly the order `groupNode` walks the group tree so that the
    /// two agree on which formula coordinate belongs to which group. They are read together: the group says what
    /// rows a cell covers, the aggregator says what those rows come to.
    static func aggNode(_ node: GroupNode, slots: [String: Int], block: Int, blockSize: Int,
                        of column: SourceColumn) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.GroupByArchive.AggNodeArchive")
        let children = node.children.map { aggNode($0, slots: slots, block: block, blockSize: blockSize, of: column) }
        m.set("formula_coord", message: coordinate(slot: slots[PathUIDs.key(node.path)] ?? 0, block: block, blockSize: blockSize))
        m.set("accum", message: accumulator(node.rows, of: column))
        if !children.isEmpty { m.set("child", messages: children) }
        return m
    }

    /// The whole cached summing of one column, for one group-by: the tree above, walked on the same slots as the
    /// group tree so the two agree on which coordinate belongs to which group, in this value's own block.
    static func aggregator(_ nodes: [GroupNode], allRows: [Int], column: SourceColumn, columnUID: ProtoMessage,
                           slots: [String: Int], block: Int, blockSize: Int) -> ProtoMessage {
        let children = nodes.map { aggNode($0, slots: slots, block: block, blockSize: blockSize, of: column) }
        var root = ProtoMessage(typeName: "TST.GroupByArchive.AggNodeArchive")
        root.set("formula_coord", message: coordinate(slot: blockSize - 1, block: block, blockSize: blockSize))
        root.set("accum", message: accumulator(allRows, of: column))
        if !children.isEmpty { root.set("child", messages: children) }
        var m = ProtoMessage(typeName: "TST.GroupByArchive.AggregatorArchive")
        m.set("column_uid", message: columnUID)
        m.set("agg_node", message: root)
        return m
    }

    /// `TST.ColumnAggregateArchive` on a group-by: which column it sums and how. The same archive the pivot's own
    /// rules carry, repeated on the group-by that caches the answer.
    static func columnAggregate(_ function: PivotDataField.Function, columnUID: ProtoMessage) -> ProtoMessage {
        var a = ProtoMessage(typeName: "TST.ColumnAggregateArchive")
        a.set("column_uid", message: columnUID)
        a.set("level", int: 0)
        a.set("agg_type", int: aggType(function))
        a.set("show_as_type", int: 0)
        a.set("column_aggregate_uid", message: NumbersUUID.random().uuid)
        return a
    }

    /// `row_uid_lookup`: the row UIDs of the copy of the source, in order, one per row including its header.
    static func rowUIDLookup(_ uids: [ProtoMessage]) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TSCE.UidLookupListArchive")
        m.set("uuids", messages: uids)
        return m
    }

    /// The root of a group tree and everything under it, and the UUIDs of its outermost nodes — which are what
    /// the pivot's order map lists, one per row or column the summary will draw (Appendix B.19).
    static func groupNodeRoot(_ nodes: [GroupNode], allRows: [Int], valueCount: Int) -> ProtoMessage {
        let (slots, blockSize) = slotMap(nodes)
        let children = nodes.map { groupNode($0, slots: slots, blockSize: blockSize, valueCount: valueCount) }
        var root = ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive")
        var uid = ProtoMessage(typeName: "TSP.UUID"); uid.set("lower", int: 1); uid.set("upper", int: 0)
        root.set("group_uid", message: uid)
        root.set("agg_formula_coords", messages: (0..<valueCount).map {
            coordinate(slot: blockSize - 1, block: $0, blockSize: blockSize)
        })
        root.set("format_manager", message: ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive.FormatManagerArchive"))
        // the root stands for every row the pivot reads, not for the first of them
        root.set("row_indexes", message: rowSet(allRows))
        root.set("row_lookup_uids", message: rowSet(allRows))
        if !children.isEmpty { root.set("child", messages: children) }
        return root
    }

    /// A `TST.GroupByArchive`: which columns it groups by, and the tree of what that grouping found. The eight
    /// bookkeeping coordinates are the ones every group-by Numbers writes carries, in the order it writes them.
    /// One grouped source column: which column, and the summary grid lane its labels are drawn along.
    ///
    /// `groupingUID` is **not an arbitrary link id**: in the reference document it is the UID of the summary
    /// grid's label lane — the label *column* for a row grouping, the heading *row* for a column grouping — and
    /// it appears identically on the pivot owner's rule lists and on the group-bys' own entries. Five unrelated
    /// random values here were what left Numbers computing every total and drawing no groups (Appendix B.19).
    struct GroupColumn { var columnUID: ProtoMessage; var groupingUID: ProtoMessage }

    static func groupColumnArchive(_ c: GroupColumn) -> ProtoMessage {
        var g = ProtoMessage(typeName: "TST.GroupColumnArchive")
        g.set("column_uid", message: c.columnUID)
        g.set("grouping_type", int: 0)
        g.set("grouping_column_uid", message: c.groupingUID)
        return g
    }

    static func groupBy(columns: [GroupColumn], nodes: [GroupNode], allRows: [Int],
                        ownerIndex: Int, uid: ProtoMessage,
                        aggregates: [(column: SourceColumn, uid: ProtoMessage, function: PivotDataField.Function)] = [],
                        rowUIDs: [ProtoMessage] = []) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.GroupByArchive")
        m.set("group_by_uid", message: uid)
        if !columns.isEmpty {
            m.set("group_column", messages: columns.map(groupColumnArchive))
        }
        m.set("group_node_root", message: groupNodeRoot(nodes, allRows: allRows, valueCount: Swift.max(1, aggregates.count)))
        // true even on a grouping with no columns: the root-only group-by a two-level column pivot keeps for its
        // grand-total lane carries is_enabled in the reference document
        m.set("is_enabled", bool: true)
        for (i, name) in ["indirect_agg_type_change_formula", "grouping_columns_formula", "grouping_column_headers_formula",
                          "aggs_in_group_root_formula", "column_order_changed_formula", "row_order_changed_formula",
                          "row_order_changed_ignoring_recalc_formula", "hidden_states_changed_formula"].enumerated() {
            var coord = ProtoMessage(typeName: "TSCE.CellCoordinateArchive")
            coord.set("column", int: i); coord.set("row", int: 0)
            m.set(name, message: coord)
        }
        m.set("owner_index", int: ownerIndex)
        // What the groups come to, one aggregator per summarised value in its own coordinate block. Numbers draws
        // this rather than adding the source up again, so a group-by without it is a column of zeroes (B.19).
        // The list is written **last value first** — the order every measured two-value document keeps, while the
        // blocks and the `column_agg_type` list stay in rule order.
        let (slots, blockSize) = slotMap(nodes)
        m.set("aggregator", messages: aggregates.enumerated().reversed().map { d, entry in
            aggregator(nodes, allRows: allRows, column: entry.column, columnUID: entry.uid,
                       slots: slots, block: d, blockSize: blockSize)
        })
        m.set("column_agg_type", messages: aggregates.map { columnAggregate($0.function, columnUID: $0.uid) })
        if !rowUIDs.isEmpty { m.set("row_uid_lookup", message: rowUIDLookup(rowUIDs)) }
        return m
    }

    // MARK: - What the pivot tells the calculation engine it reads

    /// The three references a pivot registers against its source, as a document Numbers wrote carries them: the
    /// source's first cell, the block of rows under its headings, and its heading row. Each is one reference node
    /// followed by function 168 taking it as its only argument — the marker the engine tracks a pivot's source by.
    ///
    /// Without these the pivot has rules and a cached answer but nothing telling the engine which table it reads,
    /// and Numbers draws the summary with its headings and no groups at all (Appendix B.19).
    static func formulaStore(sourceTableID: ProtoMessage, columns: Int, rows: Int) -> ProtoMessage {
        func extra() -> ProtoMessage {
            var e = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTCrossTableReferenceExtraInfoArchive")
            e.set("table_id", message: sourceTableID)
            return e
        }
        func marker() -> ProtoMessage {
            var n = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
            n.set("AST_node_type", int: 16)
            n.set("AST_function_node_index", int: 168)
            n.set("AST_function_node_numArgs", int: 1)
            return n
        }
        func column(_ index: Int) -> ProtoMessage {
            var c = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTColumnCoordinateArchive")
            c.set("column", int: index); c.set("absolute", bool: true)
            return c
        }
        func row(_ index: Int) -> ProtoMessage {
            var r = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTRowCoordinateArchive")
            r.set("row", int: index); r.set("absolute", bool: true)
            return r
        }
        func range(_ begin: Int, _ end: Int) -> ProtoMessage {
            var m = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTColonTractArchive.ASTColonTractAbsoluteRangeArchive")
            m.set("range_begin", int: begin); m.set("range_end", int: end)
            return m
        }
        func formula(_ nodes: [ProtoMessage]) -> ProtoMessage {
            var array = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive")
            array.set("AST_node", messages: nodes + [marker()])
            var f = ProtoMessage(typeName: "TSCE.FormulaArchive")
            f.set("AST_node_array", message: array)
            return f
        }

        // the first cell of the source
        var cell = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
        cell.set("AST_node_type", int: 36)
        cell.set("AST_column", message: column(0))
        cell.set("AST_row", message: row(0))
        cell.set("AST_cross_table_reference_extra_info", message: extra())

        // the block of data under the headings
        var block = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
        block.set("AST_node_type", int: 67)
        block.set("AST_cross_table_reference_extra_info", message: extra())
        var sticky = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTStickyBits")
        for bit in ["begin_row_is_absolute", "begin_column_is_absolute", "end_row_is_absolute", "end_column_is_absolute"] {
            sticky.set(bit, bool: true)
        }
        block.set("AST_sticky_bits", message: sticky)
        var tract = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTColonTractArchive")
        tract.set("absolute_column", messages: [range(0, Swift.max(0, columns - 1))])
        tract.set("absolute_row", messages: [range(1, Swift.max(1, rows))])
        tract.set("preserve_rectangular", bool: true)
        block.set("AST_colon_tract", message: tract)

        // the heading row
        var heading = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
        heading.set("AST_node_type", int: 36)
        heading.set("AST_row", message: row(0))
        heading.set("AST_cross_table_reference_extra_info", message: extra())

        var store = ProtoMessage(typeName: "TST.FormulaStoreArchive")
        store.set("next_formula_index", int: 0)
        store.set("formulas", messages: [cell, block, heading].enumerated().map { index, node in
            var pair = ProtoMessage(typeName: "TST.FormulaStoreArchive.FormulaStorePair")
            pair.set("formula_index", int: index)
            pair.set("formula", message: formula([node]))
            return pair
        })
        return store
    }

    // MARK: - The aggregate formulas the summary draws through

    /// One cell of the pivot's summary as Numbers writes it: a **formula** whose whole AST is a single
    /// `CATEGORY_REF` node naming the group-by, the summarised column, the aggregation, and the group node the
    /// cell stands for — the root sentinel for the grand total, an outermost node for an axis total, a leaf for a
    /// body cell. The cached value rides in the cell record beside the formula id. Read off the reference
    /// document's formula tables and correlated node by node (Appendix B.19).
    static func categoryFormula(groupByUID: ProtoMessage, columnUID: ProtoMessage,
                                aggregateType: Int, level: Int, groupUID: ProtoMessage) -> ProtoMessage {
        var cat = ProtoMessage(typeName: "TSCE.CategoryReferenceArchive")
        cat.set("group_by_uid", message: groupByUID)
        cat.set("column_uid", message: columnUID)
        cat.set("aggregate_type", int: aggregateType)
        cat.set("group_level", int: level)
        var flags = ProtoMessage(typeName: "TSCE.PreserveColumnRowFlagsArchive")
        flags.set("begin_row_is_absolute", bool: false)
        flags.set("begin_column_is_absolute", bool: true)
        flags.set("end_row_is_absolute", bool: false)
        flags.set("end_column_is_absolute", bool: false)
        cat.set("preserve_flags", message: flags)
        cat.set("absolute_group_uid", message: groupUID)
        cat.set("agg_index_level", int: 65535)
        var wrap = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTCategoryReferenceArchive")
        wrap.set("category_ref", message: cat)
        var node = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
        node.set("AST_node_type", int: 66)
        node.set("AST_category_ref", message: wrap)
        var array = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive")
        array.set("AST_node", messages: [node])
        var formula = ProtoMessage(typeName: "TSCE.FormulaArchive")
        formula.set("AST_node_array", message: array)
        return formula
    }

    /// Every leaf of a tree, with the rows it owns — the same walk the summary's body is laid out by, exposed so
    /// the writer can name each body cell's leaf when it writes the aggregate formulas.
    static func leafNodes(_ nodes: [GroupNode]) -> [GroupNode] {
        var out: [GroupNode] = []
        func walk(_ n: GroupNode) {
            if n.children.isEmpty { out.append(n) } else { n.children.forEach(walk) }
        }
        nodes.forEach(walk)
        return out
    }

    /// The moment a pivot says its rules were last applied. Apple's reference date is 2001-01-01; the value only
    /// has to be a time, and a fixed one keeps a document written twice from the same workbook byte-identical.
    static let refreshTimestamp: Double = 809_000_000

    /// The rules themselves.
    static func pivotOwner(_ pivot: PivotTable, uid: ProtoMessage, sourceTableUID: ProtoMessage, sourceTableName: String,
                           rowColumns: [GroupColumn], columnColumns: [GroupColumn],
                           aggregates: [(column: ProtoMessage, function: PivotDataField.Function)],
                           optionsMap: Int, formulaStore: ProtoMessage?) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.PivotOwnerArchive")
        m.set("pivot_owner_uid", message: uid)
        func list(_ columns: [GroupColumn]) -> ProtoMessage {
            var l = ProtoMessage(typeName: "TST.GroupColumnListArchive")
            l.set("group_column", messages: columns.map(groupColumnArchive))
            return l
        }
        m.set("grouping_columns_for_rows", message: list(rowColumns))
        m.set("grouping_columns_for_columns", message: list(columnColumns))
        var aggList = ProtoMessage(typeName: "TST.ColumnAggregateListArchive")
        aggList.set("aggregates", messages: aggregates.map { entry in
            var a = ProtoMessage(typeName: "TST.ColumnAggregateArchive")
            a.set("column_uid", message: entry.column)
            a.set("level", int: 0)
            a.set("agg_type", int: aggType(entry.function))
            a.set("show_as_type", int: 0)
            a.set("column_aggregate_uid", message: NumbersUUID.random().uuid)
            return a
        })
        m.set("aggregate_columns", message: aggList)
        m.set("flattening_dimension", int: 1)
        m.set("is_empty_pivot", bool: false)
        m.set("source_table_uid", message: sourceTableUID)
        m.set("source_table_name", string: sourceTableName)
        m.set("hide_grand_total_rows", bool: !pivot.showRowGrandTotals)
        m.set("hide_grand_total_columns", bool: !pivot.showColumnGrandTotals)
        m.set("grpg_col_options_map", reference: optionsMap)
        // when the rules were last applied, in Apple's reference-date seconds
        if let formulaStore { m.set("formula_store", message: formulaStore) }
        m.set("refresh_timestamp", double: refreshTimestamp)
        m.set("refresh_uid", message: NumbersUUID.random().uuid)
        m.set("row_column_rule_change_uid", message: NumbersUUID.random().uuid)
        m.set("aggregate_rule_change_uid", message: NumbersUUID.random().uuid)
        return m
    }

    /// What the model can say and a Numbers pivot cannot. None of it is dropped in silence.
    static func warnings(for pivot: PivotTable, sheet: String) -> [ConversionWarning] {
        var out: [ConversionWarning] = []
        // Written as a live pivot, and not read back as one: Numbers recomputes the summary from the copy of the
        // source rows it is given, while this library's reader takes that summary for an ordinary table. The
        // conversion keeps the pivot for Numbers and loses it for the model, and that is a loss with a name — the
        // same shape of warning the ODF data pilot carries.
        out.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet,
                                     message: "pivot table \(pivot.name) is written as a Numbers pivot: Numbers recomputes it from the source rows, and reading the file back gives its summary as an ordinary table"))
        if !pivot.pageFields.isEmpty {
            out.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet,
                                         message: "pivot table \(pivot.name): \(pivot.pageFields.count) report filter(s) dropped — a Numbers pivot has no filter field, and Numbers drops them too when it imports the same file"))
        }
        if pivot.rowFields.contains(PivotTable.valuesField) || pivot.columnFields.contains(PivotTable.valuesField) {
            out.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet,
                                         message: "pivot table \(pivot.name): the value captions have no place of their own in a Numbers pivot; they head their own columns"))
        }
        if pivot.dataFields.contains(where: { $0.showDataAs != nil }) {
            out.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet,
                                         message: "pivot table \(pivot.name): a value shown relative to another field is written as the plain summary — Numbers has the setting, this writer has no example of it"))
        }
        if pivot.styleInfo != nil {
            out.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheet,
                                         message: "pivot table \(pivot.name): its banded look is dropped; a Numbers pivot takes the document's table style"))
        }
        return out
    }
}
