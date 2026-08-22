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
