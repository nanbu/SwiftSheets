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
///   opens with every summary cell at zero, twice over on a settled reading. Numbers renders what the cache holds;
///   it does not sum the source afresh. So the remaining work on this file is to write those accumulators — this
///   computes the summary, but only into the summary's own cells.
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
    }

    /// The source rows grouped by `columns` in turn, outermost first. Values are ordered as Numbers orders them on
    /// screen: ascending, text by its own comparison, numbers numerically.
    static func group(_ rows: [Int], by columns: [SourceColumn], from level: Int = 0) -> [GroupNode] {
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
            return GroupNode(value: entry.value, rows: entry.rows,
                             children: group(entry.rows, by: columns, from: level + 1))
        }
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

    /// The cells of the summary, laid out the way Numbers lays a pivot out: the column-field headings across the
    /// top, the row-field heading down the left, and the grand totals last when they are asked for.
    ///
    /// Numbers rebuilds this from the rules when it opens the document, so this is not what Numbers shows — it is
    /// what every *other* reader shows, and what the model reads back.
    static func summaryTable(_ pivot: PivotTable, source: [SourceColumn], named name: String,
                             rowFields: [Int], columnFields: [Int], dataFields: [PivotDataField])
        -> (table: Table, headerRows: Int, headerColumns: Int) {
        var table = Table(name: name)
        let allRows = Array(1...(source.first?.values.count ?? 0))
        let rowGroups = group(allRows, by: rowFields.map { source[$0] })
        let columnGroups = group(allRows, by: columnFields.map { source[$0] })
        let headerRows = columnFields.isEmpty ? 1 : 2
        let headerColumns = rowFields.isEmpty ? 0 : 1

        // the leaves of each side, each with the rows it owns — one column of the body per column leaf per value
        func leaves(_ nodes: [GroupNode]) -> [(label: CellValue?, rows: [Int])] {
            var out: [(CellValue?, [Int])] = []
            func walk(_ n: GroupNode) {
                if n.children.isEmpty { out.append((n.value, n.rows)) } else { n.children.forEach(walk) }
            }
            nodes.forEach(walk)
            return out
        }
        let rowLeaves = leaves(rowGroups)
        let columnLeaves = leaves(columnGroups)

        // heading row(s)
        if !columnFields.isEmpty {
            table[0, 0] = .text(source[columnFields[0]].name)
            for (i, leaf) in columnLeaves.enumerated() {
                for (d, _) in dataFields.enumerated() {
                    table[0, headerColumns + i * dataFields.count + d] = leaf.label
                }
            }
            if pivot.showColumnGrandTotals {
                table[0, headerColumns + columnLeaves.count * dataFields.count] = .text("総計")
            }
        }
        let captionRow = headerRows - 1
        if !rowFields.isEmpty { table[captionRow, 0] = .text(source[rowFields[0]].name) }
        for (d, field) in dataFields.enumerated() {
            let caption = field.name ?? "\(source[field.field].name)（\(field.function.caption)）"
            if columnFields.isEmpty {
                table[captionRow, headerColumns + d] = .text(caption)
            } else if d == 0 || dataFields.count > 1 {
                table[captionRow, headerColumns + d] = .text(caption)
            }
        }

        // the body
        func write(row: Int, rows: [Int], label: CellValue?) {
            if headerColumns > 0 { table[row, 0] = label }
            let columnSets: [[Int]] = columnFields.isEmpty ? [rows] : columnLeaves.map { leaf in
                let allowed = Set(leaf.rows)
                return rows.filter { allowed.contains($0) }
            }
            for (i, set) in columnSets.enumerated() {
                for (d, field) in dataFields.enumerated() {
                    let value = summarise(set, of: source[field.field], by: field.function)
                    table[row, headerColumns + i * dataFields.count + d] = value.map { CellValue(Decimal($0)) }
                }
            }
            if !columnFields.isEmpty, pivot.showColumnGrandTotals {
                for (d, field) in dataFields.enumerated() {
                    let value = summarise(rows, of: source[field.field], by: field.function)
                    table[row, headerColumns + columnLeaves.count * dataFields.count + d] = value.map { CellValue(Decimal($0)) }
                }
            }
        }
        var r = headerRows
        for leaf in rowLeaves { write(row: r, rows: leaf.rows, label: leaf.label); r += 1 }
        if pivot.showRowGrandTotals, !rowFields.isEmpty {
            write(row: r, rows: allRows, label: .text("総計"))
        }
        return (table, headerRows, headerColumns)
    }

    // MARK: - Archives

    /// The map a pivot orders itself by: the outermost group node of each axis, in the order the summary draws
    /// them, and the sentinel `(1, 0)` Numbers keeps at the end of both lists (Appendix B.19).
    static func orderMap(columns: [ProtoMessage], rows: [ProtoMessage]) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.ColumnRowUIDMapArchive")
        var sentinel = ProtoMessage(typeName: "TSP.UUID"); sentinel.set("lower", int: 1); sentinel.set("upper", int: 0)
        m.set("sorted_column_uids", messages: columns + [sentinel])
        m.set("column_index_for_uid", ints: Array(0...columns.count))
        m.set("column_uid_for_index", ints: Array(0...columns.count))
        m.set("sorted_row_uids", messages: rows + [sentinel])
        m.set("row_index_for_uid", ints: Array(0...rows.count))
        m.set("row_uid_for_index", ints: Array(0...rows.count))
        return m
    }

    /// A `TSP.UUID` per source column, and the map the source copy carries so the rules can name a column by it.
    static func columnUIDMap(count: Int, rowCount: Int) -> (map: ProtoMessage, columns: [ProtoMessage]) {
        let columns = (0..<count).map { _ in NumbersUUID.random().uuid }
        let rows = (0..<rowCount).map { _ in NumbersUUID.random().uuid }
        var m = ProtoMessage(typeName: "TST.ColumnRowUIDMapArchive")
        m.set("sorted_column_uids", messages: columns)
        m.set("column_index_for_uid", ints: Array(0..<count))
        m.set("column_uid_for_index", ints: Array(0..<count))
        m.set("sorted_row_uids", messages: rows)
        m.set("row_index_for_uid", ints: Array(0..<rowCount))
        m.set("row_uid_for_index", ints: Array(0..<rowCount))
        return (m, columns)
    }

    /// A run of row numbers as Numbers spells a set of them: one entry per row, carrying only where it begins.
    static func rowSet(_ rows: [Int]) -> ProtoMessage {
        var set = ProtoMessage(typeName: "TSCE.IndexSetArchive")
        set.set("entries", messages: rows.sorted().map { row in
            var e = ProtoMessage(typeName: "TSCE.IndexSetArchive.IndexSetEntry")
            e.set("range_begin", int: row)
            return e
        })
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

    /// One node of the tree Numbers reads to know what groups there are. `coordinate` walks upward as nodes are
    /// laid down: every node owns a slot in the group-by's own formula coordinate space, and Numbers keeps the
    /// bookkeeping slots 0…7 for itself.
    static func groupNode(_ node: GroupNode, coordinate: inout Int, uids: inout [ProtoMessage], depth: Int = 0) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive")
        let uid = NumbersUUID.random().uuid
        if depth == 0 { uids.append(uid) }        // the outermost level is the axis the pivot orders by
        m.set("group_uid", message: uid)
        let children = node.children.map { groupNode($0, coordinate: &coordinate, uids: &uids, depth: depth + 1) }
        var coord = ProtoMessage(typeName: "TSCE.CellCoordinateArchive")
        coord.set("column", int: coordinate); coord.set("row", int: 0)
        coordinate += 1
        m.set("agg_formula_coords", messages: [coord])
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

    /// The root of a group tree and everything under it, and the UUIDs of its outermost nodes — which are what
    /// the pivot's order map lists, one per row or column the summary will draw (Appendix B.19).
    static func groupNodeRoot(_ nodes: [GroupNode], allRows: [Int]) -> (root: ProtoMessage, outermost: [ProtoMessage]) {
        var coordinate = 8                                   // 0…7 are the group-by's own bookkeeping slots
        var outermost: [ProtoMessage] = []
        let children = nodes.map { groupNode($0, coordinate: &coordinate, uids: &outermost) }
        var root = ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive")
        var uid = ProtoMessage(typeName: "TSP.UUID"); uid.set("lower", int: 1); uid.set("upper", int: 0)
        root.set("group_uid", message: uid)
        var coord = ProtoMessage(typeName: "TSCE.CellCoordinateArchive")
        coord.set("column", int: coordinate); coord.set("row", int: 0)
        root.set("agg_formula_coords", messages: [coord])
        root.set("format_manager", message: ProtoMessage(typeName: "TST.GroupByArchive.GroupNodeArchive.FormatManagerArchive"))
        root.set("row_indexes", message: rowSet(Array(allRows.prefix(1))))
        root.set("row_lookup_uids", message: rowSet(Array(allRows.prefix(1))))
        if !children.isEmpty { root.set("child", messages: children) }
        return (root, outermost)
    }

    /// A `TST.GroupByArchive`: which columns it groups by, and the tree of what that grouping found. The eight
    /// bookkeeping coordinates are the ones every group-by Numbers writes carries, in the order it writes them.
    static func groupBy(columns: [ProtoMessage], nodes: [GroupNode], allRows: [Int],
                        ownerIndex: Int, uid: ProtoMessage) -> (archive: ProtoMessage, outermost: [ProtoMessage]) {
        var m = ProtoMessage(typeName: "TST.GroupByArchive")
        m.set("group_by_uid", message: uid)
        if !columns.isEmpty {
            m.set("group_column", messages: columns.map { column in
                var g = ProtoMessage(typeName: "TST.GroupColumnArchive")
                g.set("column_uid", message: column)
                g.set("grouping_type", int: 0)
                g.set("grouping_column_uid", message: NumbersUUID.random().uuid)
                return g
            })
        }
        let built = groupNodeRoot(nodes, allRows: allRows)
        m.set("group_node_root", message: built.root)
        m.set("is_enabled", bool: !columns.isEmpty)
        for (i, name) in ["indirect_agg_type_change_formula", "grouping_columns_formula", "grouping_column_headers_formula",
                          "aggs_in_group_root_formula", "column_order_changed_formula", "row_order_changed_formula",
                          "row_order_changed_ignoring_recalc_formula", "hidden_states_changed_formula"].enumerated() {
            var coord = ProtoMessage(typeName: "TSCE.CellCoordinateArchive")
            coord.set("column", int: i); coord.set("row", int: 0)
            m.set(name, message: coord)
        }
        m.set("owner_index", int: ownerIndex)
        return (m, built.outermost)
    }

    /// The rules themselves.
    static func pivotOwner(_ pivot: PivotTable, uid: ProtoMessage, sourceTableUID: ProtoMessage, sourceTableName: String,
                           rowColumns: [ProtoMessage], columnColumns: [ProtoMessage],
                           aggregates: [(column: ProtoMessage, function: PivotDataField.Function)],
                           optionsMap: Int) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TST.PivotOwnerArchive")
        m.set("pivot_owner_uid", message: uid)
        func list(_ columns: [ProtoMessage]) -> ProtoMessage {
            var l = ProtoMessage(typeName: "TST.GroupColumnListArchive")
            l.set("group_column", messages: columns.map { column in
                var g = ProtoMessage(typeName: "TST.GroupColumnArchive")
                g.set("column_uid", message: column)
                g.set("grouping_type", int: 0)
                g.set("grouping_column_uid", message: NumbersUUID.random().uuid)
                return g
            })
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
        m.set("refresh_uid", message: NumbersUUID.random().uuid)
        m.set("row_column_rule_change_uid", message: NumbersUUID.random().uuid)
        m.set("aggregate_rule_change_uid", message: NumbersUUID.random().uuid)
        return m
    }

    /// What the model can say and a Numbers pivot cannot. None of it is dropped in silence.
    static func warnings(for pivot: PivotTable, sheet: String) -> [ConversionWarning] {
        var out: [ConversionWarning] = []
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
