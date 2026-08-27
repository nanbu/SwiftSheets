import Foundation
import SheetCore

/// Turns a `TSCE.FormulaArchive` (a postfix node array) back into formula text in the XLSX dialect, which
/// `FormulaExpr.parse` then reads. Function names come from the machine-extracted function table.
struct NumbersFormulaDecoder {
    let schema = NumbersSchema.shared
    /// Resolves a cross-table UUID to "Sheet::Table" for the sheet-name slot of a reference.
    let tableName: (String) -> String?
    var problems: [String] = []

    private var stack: [String] = []

    init(tableName: @escaping (String) -> String?) { self.tableName = tableName }

    /// The unnamed function Numbers spreads an array formula with: every covered cell holds
    /// `337(anchor)` and shows its own element of the anchor's result (Appendix B.26). Apple never named it
    /// in the Protobuf; numbers-parser renders it `UNDEFINED!`.
    static let spillFunctionIndex = 337

    /// The anchor a spill cell points at, when `formula` is exactly Numbers' spill shape — one cell reference
    /// into function 337 — or nil for any other formula. The reader turns the cells naming one anchor back into
    /// `Table.arrayFormulas`, the model's word for an array formula's range.
    static func spillAnchor(_ formula: ProtoMessage, row: Int, col: Int) -> CellRef? {
        guard let nodes = formula.message("AST_node_array")?.messages("AST_node"), nodes.count == 2 else { return nil }
        let types = NumbersSchema.shared.enums["TSCE.ASTNodeArrayArchive.ASTNodeType"] ?? [:]
        guard nodes[1].int("AST_node_type") == types["FUNCTION_NODE"],
              nodes[1].int("AST_function_node_index") == spillFunctionIndex,
              nodes[0].int("AST_node_type") == types["CELL_REFERENCE_NODE"],
              let rowNode = nodes[0].message("AST_row"), let colNode = nodes[0].message("AST_column") else { return nil }
        let r = (rowNode.bool("absolute") ?? false) ? (rowNode.int("row") ?? 0) : row + (rowNode.int("row") ?? 0)
        let c = (colNode.bool("absolute") ?? false) ? (colNode.int("column") ?? 0) : col + (colNode.int("column") ?? 0)
        guard r >= 0, c >= 0, r <= CellRef.maxRow, c <= CellRef.maxCol else { return nil }
        return CellRef(row: r, col: c)
    }

    mutating func text(for formula: ProtoMessage, row: Int, col: Int) -> String? {
        stack = []
        guard let array = formula.message("AST_node_array") else { return nil }
        let types = schema.enums["TSCE.ASTNodeArrayArchive.ASTNodeType"] ?? [:]
        let typeName = Dictionary(types.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for node in array.messages("AST_node") {
            let kind = typeName[node.int("AST_node_type") ?? -1] ?? "?"
            switch kind {
            case "ADDITION_NODE": binary("+")
            case "SUBTRACTION_NODE": binary("-")
            case "MULTIPLICATION_NODE": binary("*")
            case "DIVISION_NODE": binary("/")
            case "POWER_NODE": binary("^")
            case "CONCATENATION_NODE": binary("&")
            case "EQUAL_TO_NODE": binary("=")
            case "NOT_EQUAL_TO_NODE": binary("<>")
            case "GREATER_THAN_NODE": binary(">")
            case "GREATER_THAN_OR_EQUAL_TO_NODE": binary(">=")
            case "LESS_THAN_NODE": binary("<")
            case "LESS_THAN_OR_EQUAL_TO_NODE": binary("<=")
            case "NEGATION_NODE": let a = pop(); push("-" + paren(a))
            case "PLUS_SIGN_NODE": break
            case "PERCENT_NODE": let a = pop(); push(a + "%")
            case "NUMBER_NODE":
                if node.uint("AST_number_node_decimal_high") == 0x3040000000000000, let low = node.uint("AST_number_node_decimal_low") { push(String(low)) }
                else if let d = node.double("AST_number_node_number") { push(numberText(d)) }
                else { push("0") }
            case "BOOLEAN_NODE", "TOKEN_NODE":
                let v = node.bool("AST_token_node_boolean") ?? node.bool("AST_boolean_node_boolean") ?? false
                push(v ? "TRUE" : "FALSE")
            case "STRING_NODE": push("\"" + (node.string("AST_string_node_string") ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            case "DATE_NODE":
                let seconds = node.double("AST_date_node_dateNum") ?? 0
                let day = CivilDate(dayNumber: NumbersReader.epochDay + Int((seconds / 86400).rounded(.down)))
                push("DATE(\(day.year),\(day.month),\(day.day))")
            case "EMPTY_ARGUMENT_NODE": push("")
            case "FUNCTION_NODE":
                let n = node.int("AST_function_node_numArgs") ?? 0
                let index = node.int("AST_function_node_index") ?? -1
                let name = schema.functions[index] ?? "UNDEFINED!"
                if schema.functions[index] == nil { problems.append("function id \(index) is unknown") }
                let args = popN(Swift.min(n, stack.count))
                push(name + "(" + args.joined(separator: ",") + ")")
            case "UNKNOWN_FUNCTION_NODE":
                let n = node.int("AST_unknown_function_node_numArgs") ?? 0
                let args = popN(Swift.min(n, stack.count))
                push((node.string("AST_unknown_function_node_string") ?? "UNKNOWN") + "(" + args.joined(separator: ",") + ")")
            case "LIST_NODE":
                let n = node.int("AST_list_node_numArgs") ?? 0
                push("(" + popN(Swift.min(n, stack.count)).joined(separator: ",") + ")")
            case "ARRAY_NODE":
                let rows = node.int("AST_array_node_numRow") ?? 1, cols = node.int("AST_array_node_numCol") ?? 1
                var lines: [String] = []
                for _ in 0..<rows { lines.append(popN(Swift.min(cols, stack.count)).joined(separator: ",")) }
                push("{" + lines.reversed().joined(separator: ";") + "}")
            case "CELL_REFERENCE_NODE", "COLON_TRACT_NODE": push(reference(node, row: row, col: col))
            case "COLON_NODE", "COLON_NODE_WITH_UIDS":
                let b = pop(), a = pop()
                push(a + ":" + b)
            case "REFERENCE_ERROR_NODE", "REFERENCE_ERROR_WITH_UIDS": push("#REF!")
            case "APPEND_WHITESPACE_NODE", "PREPEND_WHITESPACE_NODE", "BEGIN_THUNK_NODE", "END_THUNK_NODE", "BEGIN_EMBEDDED_NODE_ARRAY": break
            default:
                problems.append("node type \(kind) is unsupported")
                return nil
            }
        }
        return stack.count == 1 ? stack[0] : (stack.isEmpty ? nil : stack.joined())
    }

    private mutating func push(_ s: String) { stack.append(s) }
    private mutating func pop() -> String { stack.popLast() ?? "" }
    private mutating func popN(_ n: Int) -> [String] { var out: [String] = []; for _ in 0..<n { out.append(pop()) }; return out.reversed() }
    private mutating func binary(_ op: String) { let b = pop(), a = pop(); push(a + op + b) }
    private func paren(_ s: String) -> String { s.contains(where: { "+-*/^&=<>".contains($0) }) && !s.hasPrefix("(") ? "(" + s + ")" : s }

    private func numberText(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        let s = "\(d)"
        return s.contains("e") ? Decimal(string: s).map { "\($0)" } ?? s : s
    }

    /// `A1`, `$B$2`, `A:B`, `3:5`, `'Sheet::Table'!A1` — relative coordinates are resolved against the host cell.
    private func reference(_ node: ProtoMessage, row: Int, col: Int) -> String {
        var prefix = ""
        if let extra = node.message("AST_cross_table_reference_extra_info"), let hex = NumbersUUID.hex(extra.message("table_id")) {
            prefix = CellRef.formulaSheetName(tableName(hex) ?? "?") + "!"
        }
        if let tract = node.message("AST_colon_tract") {
            let sticky = node.message("AST_sticky_bits")
            func resolve(_ abs: Bool, _ absolute: [ProtoMessage], _ relative: [ProtoMessage], _ offset: Int, _ max: Int, end: Bool) -> Int {
                func rangeEnd(_ m: ProtoMessage) -> Int { m.int("range_end") ?? m.int("range_begin") ?? 0 }
                func value(_ m: ProtoMessage) -> Int { end ? rangeEnd(m) : (m.int("range_begin") ?? 0) }
                if abs, let a = absolute.first { return value(a) }
                if relative.isEmpty, let a = absolute.first, value(a) == max { return max }
                if let r = relative.first { return offset + value(r) }
                return max
            }
            let absR = tract.messages("absolute_row"), relR = tract.messages("relative_row"), absC = tract.messages("absolute_column"), relC = tract.messages("relative_column")
            let r0 = resolve(sticky?.bool("begin_row_is_absolute") ?? false, absR, relR, row, 0x7FFF_FFFF, end: false)
            let r1 = resolve(sticky?.bool("end_row_is_absolute") ?? false, absR, relR, row, 0x7FFF_FFFF, end: true)
            let c0 = resolve(sticky?.bool("begin_column_is_absolute") ?? false, absC, relC, col, 0x7FFF, end: false)
            let c1 = resolve(sticky?.bool("end_column_is_absolute") ?? false, absC, relC, col, 0x7FFF, end: true)
            let rowsOpen = r0 == 0x7FFF_FFFF, colsOpen = c0 == 0x7FFF
            let ar0 = sticky?.bool("begin_row_is_absolute") ?? false, ar1 = sticky?.bool("end_row_is_absolute") ?? false
            let ac0 = sticky?.bool("begin_column_is_absolute") ?? false, ac1 = sticky?.bool("end_column_is_absolute") ?? false
            if rowsOpen { return prefix + (ac0 ? "$" : "") + CellRef.columnName(c0) + ":" + (ac1 ? "$" : "") + CellRef.columnName(c1) }
            if colsOpen { return prefix + (ar0 ? "$" : "") + String(r0 + 1) + ":" + (ar1 ? "$" : "") + String(r1 + 1) }
            let a = (ac0 ? "$" : "") + CellRef.columnName(c0) + (ar0 ? "$" : "") + String(r0 + 1)
            let b = (ac1 ? "$" : "") + CellRef.columnName(c1) + (ar1 ? "$" : "") + String(r1 + 1)
            return prefix + (a == b && !(ac0 != ac1 || ar0 != ar1) ? a : a + ":" + b)
        }
        let rowNode = node.message("AST_row"), colNode = node.message("AST_column")
        let absRow = rowNode?.bool("absolute") ?? false, absCol = colNode?.bool("absolute") ?? false
        let r = rowNode.map { absRow ? ($0.int("row") ?? 0) : row + ($0.int("row") ?? 0) }
        let c = colNode.map { absCol ? ($0.int("column") ?? 0) : col + ($0.int("column") ?? 0) }
        if let r, colNode == nil { return prefix + (absRow ? "$" : "") + String(r + 1) + ":" + (absRow ? "$" : "") + String(r + 1) }
        if let c, rowNode == nil { return prefix + (absCol ? "$" : "") + CellRef.columnName(c) + ":" + (absCol ? "$" : "") + CellRef.columnName(c) }
        return prefix + (absCol ? "$" : "") + CellRef.columnName(c ?? 0) + (absRow ? "$" : "") + String((r ?? 0) + 1)
    }
}

/// The way back: a `FormulaExpr` becomes the postfix node array Numbers evaluates (`TSCE.FormulaArchive`), so a
/// formula written to a Numbers document is a formula there and not only its last computed value (spec Appendix B.18).
///
/// The node shapes are the ones observed in the fixture corpus — the same documents the decoder above was written
/// against, read back field by field. What no document in the corpus shows, this refuses to invent: a reference to
/// another table, a defined name, the intersection and union operators, a function Numbers does not have. Each of
/// those answers `nil`, and the writer falls back to the cached value and says so. Guessing a shape here would not
/// fail loudly — Numbers would offer to repair the document, or quietly compute something else.
struct NumbersFormulaEncoder {
    private let schema = NumbersSchema.shared
    private let nodeTypes: [String: Int]
    /// The table the formula lives in, as `Sheet::Table`.
    let hostTable: String
    /// The UUID of a table a reference names, as `TSP.CFUUIDArchive`. A reference to a table this cannot find is
    /// refused rather than written pointing nowhere.
    let tableUUID: (String) -> ProtoMessage?
    private(set) var problems: [String] = []

    init(hostTable: String, tableUUID: @escaping (String) -> ProtoMessage? = { _ in nil }) {
        self.hostTable = hostTable
        self.tableUUID = tableUUID
        nodeTypes = NumbersSchema.shared.enums["TSCE.ASTNodeArrayArchive.ASTNodeType"] ?? [:]
    }

    /// The archive for one cell's formula, or nil when some part of it has no Numbers spelling we have seen.
    /// `row` / `col` are the cell's own coordinates: Numbers stores a relative reference as the offset from them.
    mutating func archive(for expr: FormulaExpr, row: Int, col: Int) -> ProtoMessage? {
        var nodes: [ProtoMessage] = []
        guard emit(expr, row: row, col: col, into: &nodes) else { return nil }
        var array = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive")
        array.set("AST_node", messages: nodes)
        var formula = ProtoMessage(typeName: "TSCE.FormulaArchive")
        formula.set("AST_node_array", message: array)
        return formula
    }

    // No `spillArchive` here on purpose: writing Numbers' spill shape (`337(anchor)`) was tried and measured
    // dead — the function does not survive Numbers' load-time recalculation, which every document written from
    // the old-version template goes through. Even Numbers' own spread, version-faked old, loses its values on
    // open (Appendix B.26). The covered cells' values are written instead, and the writer says so.

    private mutating func node(_ type: String) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
        m.set("AST_node_type", int: nodeTypes[type] ?? 0)
        return m
    }

    private mutating func fail(_ why: String) -> Bool {
        problems.append(why)
        return false
    }

    private mutating func emit(_ expr: FormulaExpr, row: Int, col: Int, into nodes: inout [ProtoMessage]) -> Bool {
        switch expr {
        case .number(let d):
            var n = node("NUMBER_NODE")
            n.set("AST_number_node_number", double: NSDecimalNumber(decimal: d).doubleValue)
            let bytes = CellStorage.encodeDecimal128(d)
            n.set("AST_number_node_decimal_low", uint: NumbersFormulaEncoder.littleEndian(bytes[0..<8]))
            n.set("AST_number_node_decimal_high", uint: NumbersFormulaEncoder.littleEndian(bytes[8..<16]))
            nodes.append(n)
        case .string(let s):
            var n = node("STRING_NODE")
            n.set("AST_string_node_string", string: s)
            nodes.append(n)
        case .boolean(let b):
            var n = node("BOOLEAN_NODE")
            n.set("AST_boolean_node_boolean", bool: b)
            nodes.append(n)
        case .missing:
            nodes.append(node("EMPTY_ARGUMENT_NODE"))
        case .ref(let ref, let sheet, let absRow, let absCol):
            guard let extra = crossTable(sheet) else { return fail("no table is named \(sheet ?? "?")") }
            var n = node("CELL_REFERENCE_NODE")
            n.set("AST_row", message: rowCoordinate(ref.row, absolute: absRow, host: row))
            n.set("AST_column", message: columnCoordinate(ref.col, absolute: absCol, host: col))
            if case .other(let info) = extra { n.set("AST_cross_table_reference_extra_info", message: info) }
            nodes.append(n)
        case .column(let index, let sheet, let abs):
            guard let extra = crossTable(sheet) else { return fail("no table is named \(sheet ?? "?")") }
            var n = node("CELL_REFERENCE_NODE")
            n.set("AST_column", message: columnCoordinate(index, absolute: abs, host: col))
            if case .other(let info) = extra { n.set("AST_cross_table_reference_extra_info", message: info) }
            nodes.append(n)
        case .row(let index, let sheet, let abs):
            guard let extra = crossTable(sheet) else { return fail("no table is named \(sheet ?? "?")") }
            var n = node("CELL_REFERENCE_NODE")
            n.set("AST_row", message: rowCoordinate(index, absolute: abs, host: row))
            if case .other(let info) = extra { n.set("AST_cross_table_reference_extra_info", message: info) }
            nodes.append(n)
        case .range(let a, let b):
            // A whole column or row is one node in Numbers, not two bound with a colon: `A:A` comes back from the
            // corpus as a single reference carrying only its column. A range *between* two of them (`A:C`) is a
            // colon tract, whose shape no fixture shows, so it is refused rather than guessed at.
            if case .column(let i, let sheet, let abs) = a, case .column(let j, _, _) = b {
                guard i == j else { return fail("a range over whole columns (A:C) has no shape we have seen in a Numbers document") }
                return emit(.column(i, sheet: sheet, abs: abs), row: row, col: col, into: &nodes)
            }
            if case .row(let i, let sheet, let abs) = a, case .row(let j, _, _) = b {
                guard i == j else { return fail("a range over whole rows (1:3) has no shape we have seen in a Numbers document") }
                return emit(.row(i, sheet: sheet, abs: abs), row: row, col: col, into: &nodes)
            }
            guard emit(a, row: row, col: col, into: &nodes), emit(b, row: row, col: col, into: &nodes) else { return false }
            nodes.append(node("COLON_NODE"))
        case .unary(let op, let e):
            guard emit(e, row: row, col: col, into: &nodes) else { return false }
            switch op {
            case .negate: nodes.append(node("NEGATION_NODE"))
            case .plus: break                                   // Numbers drops a leading `+`, as the decoder does
            case .percent: nodes.append(node("PERCENT_NODE"))
            default: return fail("\(op.symbol) is not a prefix operator")
            }
        case .binary(let op, let a, let b):
            guard let type = NumbersFormulaEncoder.binaryNodes[op] else {
                return fail(op == .intersect ? "the intersection operator has no shape we have seen in a Numbers document"
                                             : "the union operator has no shape we have seen in a Numbers document")
            }
            guard emit(a, row: row, col: col, into: &nodes), emit(b, row: row, col: col, into: &nodes) else { return false }
            nodes.append(node(type))
        case .call(let name, let args):
            let upper = name.uppercased()
            guard let index = schema.functionIndexes[upper] else { return fail("Numbers has no function \(upper)") }
            for a in args {
                guard emit(a, row: row, col: col, into: &nodes) else { return false }
            }
            var n = node("FUNCTION_NODE")
            n.set("AST_function_node_index", int: index)
            n.set("AST_function_node_numArgs", int: args.count)
            nodes.append(n)
        case .array(let rows):
            let width = rows.first?.count ?? 0
            guard rows.allSatisfy({ $0.count == width }) else { return fail("an array constant with rows of different lengths") }
            for line in rows {
                for element in line {
                    guard emit(element, row: row, col: col, into: &nodes) else { return false }
                }
            }
            var n = node("ARRAY_NODE")
            n.set("AST_array_node_numRow", int: rows.count)
            n.set("AST_array_node_numCol", int: width)
            nodes.append(n)
        case .name(let text, _):
            return fail("Numbers has no defined names (\(text))")
        case .error(let e):
            return fail("an error literal (\(e)) has no shape we have seen in a Numbers document")
        case .unparsed:
            return fail("the formula could not be parsed, so it cannot be translated")
        }
        return true
    }

    /// What a reference has to carry to name a table: nothing when it is the formula's own table, and the target's
    /// UUID when it is another. `nil` means no such table, which is a reference that cannot be written.
    ///
    /// The coordinates stay **relative to the cell holding the formula** even when the reference crosses tables —
    /// that is what Numbers writes, however odd it reads (Appendix B.18).
    private enum Target { case ownTable, other(ProtoMessage) }

    private func crossTable(_ sheet: String?) -> Target? {
        guard let sheet else { return .ownTable }
        if sheet == hostTable || sheet == hostTable.components(separatedBy: "::").last { return .ownTable }
        guard let uuid = tableUUID(sheet) else { return nil }
        var extra = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTCrossTableReferenceExtraInfoArchive")
        extra.set("table_id", message: uuid)
        return .other(extra)
    }

    private func rowCoordinate(_ index: Int, absolute: Bool, host: Int) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTRowCoordinateArchive")
        m.set("row", int: absolute ? index : index - host)
        m.set("absolute", bool: absolute)
        return m
    }

    private func columnCoordinate(_ index: Int, absolute: Bool, host: Int) -> ProtoMessage {
        var m = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTColumnCoordinateArchive")
        m.set("column", int: absolute ? index : index - host)
        m.set("absolute", bool: absolute)
        return m
    }

    private static let binaryNodes: [FormulaOp: String] = [
        .add: "ADDITION_NODE", .subtract: "SUBTRACTION_NODE", .multiply: "MULTIPLICATION_NODE",
        .divide: "DIVISION_NODE", .power: "POWER_NODE", .concat: "CONCATENATION_NODE",
        .equal: "EQUAL_TO_NODE", .notEqual: "NOT_EQUAL_TO_NODE", .less: "LESS_THAN_NODE",
        .lessOrEqual: "LESS_THAN_OR_EQUAL_TO_NODE", .greater: "GREATER_THAN_NODE",
        .greaterOrEqual: "GREATER_THAN_OR_EQUAL_TO_NODE",
    ]

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }
}
