import Foundation

/// Lexer + Pratt parser for XLSX and ODS (OpenFormula) formula text. Whitespace between tokens is dropped (the
/// intersection operator is not supported — such formulas fall back to `.unparsed`).
struct FormulaParser {
    enum Token: Equatable {
        case number(Decimal)
        case string(String)
        case error(String)
        case ref(CellRef, sheet: String?, absRow: Bool, absCol: Bool)
        case column(Int, sheet: String?, abs: Bool)
        case row(Int, sheet: String?, abs: Bool)
        case name(String, sheet: String?)
        case function(String)        // identifier followed by "("
        case op(String)              // + - * / ^ & = <> < <= > >= %
        case lparen, rparen, lbrace, rbrace, colon, separator, rowSeparator   // "," / ";" per dialect
        case end
    }

    let dialect: SheetFormat
    private var tokens: [Token] = []
    private var pos = 0

    init(_ text: String, dialect: SheetFormat) throws {
        self.dialect = dialect
        var lexer = FormulaLexer(text, dialect: dialect)
        tokens = try lexer.tokenize()
    }

    /// Drops "=" (and ODS's "of:=" / "oooc:=" namespace prefixes).
    static func stripPrefix(_ text: String, dialect: SheetFormat) -> String {
        var s = text
        if dialect == .ods {
            for p in ["of:=", "oooc:=", "msoxl:="] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); return s }
        }
        if s.hasPrefix("=") { s.removeFirst() }
        return s
    }

    private var current: Token { pos < tokens.count ? tokens[pos] : .end }
    private mutating func advance() { pos += 1 }
    private func fail(_ detail: String) -> SheetError { .formulaSyntax(offset: pos, detail: detail) }

    mutating func parseFormula() throws -> FormulaExpr {
        let e = try parseExpression(minPrecedence: 0)
        guard current == .end else { throw fail("unexpected token after expression") }
        return e
    }

    private mutating func parseExpression(minPrecedence: Int) throws -> FormulaExpr {
        var left = try parsePrefix()
        while true {
            guard case .op(let sym) = current, let op = FormulaParser.binaryOp(sym) else { break }
            let prec = op.precedence
            guard prec >= minPrecedence else { break }
            advance()
            if op == .percent { left = .unary(.percent, left); continue }
            // every binary operator is left-associative in Excel (2^3^2 = 64)
            let right = try parseExpression(minPrecedence: prec + 1)
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func parsePrefix() throws -> FormulaExpr {
        switch current {
        case .op("-"): advance(); return .unary(.negate, try parseExpression(minPrecedence: FormulaOp.negate.precedence))
        case .op("+"): advance(); return .unary(.plus, try parseExpression(minPrecedence: FormulaOp.plus.precedence))
        default: return try parsePostfixRange()
        }
    }

    /// A primary, then any number of `:` joins (ranges bind tightest).
    private mutating func parsePostfixRange() throws -> FormulaExpr {
        var e = try parsePrimary()
        while current == .colon {
            advance()
            let rhs = try parsePrimary()
            e = .range(e, FormulaParser.inheritSheet(from: e, rhs))
        }
        return e
    }

    /// `Sheet1!A1:B2` — the sheet prefix applies to both endpoints.
    static func inheritSheet(from lhs: FormulaExpr, _ rhs: FormulaExpr) -> FormulaExpr {
        guard let s = FormulaExpr.sheetOf(lhs) else { return rhs }
        switch rhs {
        case .ref(let r, nil, let ar, let ac): return .ref(r, sheet: s, absRow: ar, absCol: ac)
        case .column(let c, nil, let a): return .column(c, sheet: s, abs: a)
        case .row(let r, nil, let a): return .row(r, sheet: s, abs: a)
        default: return rhs
        }
    }

    private mutating func parsePrimary() throws -> FormulaExpr {
        let t = current
        switch t {
        case .number(let d): advance(); return .number(d)
        case .string(let s): advance(); return .string(s)
        case .error(let e): advance(); return .error(e)
        case .ref(let r, let s, let ar, let ac): advance(); return .ref(r, sheet: s, absRow: ar, absCol: ac)
        case .column(let c, let s, let a): advance(); return .column(c, sheet: s, abs: a)
        case .row(let r, let s, let a): advance(); return .row(r, sheet: s, abs: a)
        case .name(let n, let s):
            advance()
            switch n.uppercased() {
            case "TRUE" where s == nil: return .boolean(true)
            case "FALSE" where s == nil: return .boolean(false)
            default: return .name(n, sheet: s)
            }
        case .function(let name):
            advance()
            guard current == .lparen else { throw fail("expected ( after \(name)") }
            advance()
            var args: [FormulaExpr] = []
            if current == .rparen { advance(); return .call(name: FormulaParser.canonicalFunctionName(name), args: []) }
            while true {
                if current == .separator || current == .rparen { args.append(.missing) }
                else { args.append(try parseExpression(minPrecedence: 0)) }
                if current == .separator { advance(); continue }
                guard current == .rparen else { throw fail("expected ) in call to \(name)") }
                advance()
                break
            }
            return .call(name: FormulaParser.canonicalFunctionName(name), args: args)
        case .lparen:
            advance()
            var e = try parseExpression(minPrecedence: 0)
            // (A1,B2) — the union operator only exists inside parentheses
            while current == .separator, dialect == .xlsx {
                advance()
                let rhs = try parseExpression(minPrecedence: 0)
                e = .binary(.union, e, rhs)
            }
            guard current == .rparen else { throw fail("expected )") }
            advance()
            return e
        case .lbrace:
            advance()
            var rows: [[FormulaExpr]] = [[]]
            while true {
                switch current {
                case .rbrace: advance(); return .array(rows)
                case .separator: advance()
                case .rowSeparator: advance(); rows.append([])
                case .end: throw fail("unterminated array constant")
                default:
                    let e = try parsePrefix()
                    switch e {
                    case .number, .string, .boolean, .error, .unary(.negate, .number): rows[rows.count - 1].append(e)
                    default: throw fail("array constants may only hold literals")
                    }
                }
            }
        default: throw fail("unexpected token")
        }
    }

    static func binaryOp(_ sym: String) -> FormulaOp? {
        switch sym {
        case "+": .add
        case "-": .subtract
        case "*": .multiply
        case "/": .divide
        case "^": .power
        case "&": .concat
        case "=": .equal
        case "<>": .notEqual
        case "<": .less
        case "<=": .lessOrEqual
        case ">": .greater
        case ">=": .greaterOrEqual
        case "%": .percent
        case "~": .union
        default: nil
        }
    }

    /// Upper-case canonical names; namespace prefixes such as `_xlfn.` keep their case (Excel requires it).
    static func canonicalFunctionName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name.uppercased() }
        return String(name[...dot]) + name[name.index(after: dot)...].uppercased()
    }
}

/// Character-level tokenizer.
struct FormulaLexer {
    let chars: [Character]
    let dialect: SheetFormat
    private var i = 0
    private var tokens: [FormulaParser.Token] = []

    init(_ text: String, dialect: SheetFormat) { chars = Array(text); self.dialect = dialect }

    private func fail(_ detail: String) -> SheetError { .formulaSyntax(offset: i, detail: detail) }
    private func peek(_ offset: Int = 0) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
    private static func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "\\" }
    private static func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." || c == "?" || c == "\\" }

    mutating func tokenize() throws -> [FormulaParser.Token] {
        while let c = peek() {
            if c == " " || c == "\n" || c == "\r" || c == "\t" { i += 1; continue }
            switch c {
            case "(": tokens.append(.lparen); i += 1
            case ")": tokens.append(.rparen); i += 1
            case "{": tokens.append(.lbrace); i += 1
            case "}": tokens.append(.rbrace); i += 1
            case ":": tokens.append(.colon); i += 1
            case ",": tokens.append(.separator); i += 1
            case ";": tokens.append(dialect == .ods ? .separator : .rowSeparator); i += 1
            case "|" where dialect == .ods: tokens.append(.rowSeparator); i += 1
            case "~" where dialect == .ods: tokens.append(.op("~")); i += 1   // OpenFormula's reference union
            case "+", "-", "*", "/", "^", "&", "%", "=": tokens.append(.op(String(c))); i += 1
            case "<":
                if peek(1) == ">" { tokens.append(.op("<>")); i += 2 } else if peek(1) == "=" { tokens.append(.op("<=")); i += 2 } else { tokens.append(.op("<")); i += 1 }
            case ">":
                if peek(1) == "=" { tokens.append(.op(">=")); i += 2 } else { tokens.append(.op(">")); i += 1 }
            case "\"": tokens.append(.string(try lexString()))
            case "#": tokens.append(.error(try lexError()))
            case "[" where dialect == .ods: try lexODSReference()
            case "'": try lexReferenceLike()
            default:
                if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                    if let t = lexRowRange() { tokens.append(t) } else { tokens.append(.number(try lexNumber())) }
                } else if FormulaLexer.isIdentStart(c) || c == "$" {
                    try lexReferenceLike()
                } else { throw fail("unexpected character \(c)") }
            }
        }
        return tokens
    }

    private mutating func lexString() throws -> String {
        i += 1
        var s = ""
        while let c = peek() {
            if c == "\"" {
                if peek(1) == "\"" { s.append("\""); i += 2; continue }
                i += 1
                return s
            }
            s.append(c); i += 1
        }
        throw fail("unterminated string")
    }

    private mutating func lexError() throws -> String {
        for code in ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A", "#GETTING_DATA", "#SPILL!", "#CALC!"] {
            if String(chars[i..<Swift.min(chars.count, i + code.count)]) == code { i += code.count; return code }
        }
        throw fail("unknown error literal")
    }

    private mutating func lexNumber() throws -> Decimal {
        var s = ""
        while let c = peek(), c.isNumber { s.append(c); i += 1 }
        if peek() == "." { s.append("."); i += 1; while let c = peek(), c.isNumber { s.append(c); i += 1 } }
        if let e = peek(), e == "e" || e == "E", let n = peek(1), n.isNumber || ((n == "+" || n == "-") && (peek(2)?.isNumber ?? false)) {
            s.append("e"); i += 1
            if let sign = peek(), sign == "+" || sign == "-" { s.append(sign); i += 1 }
            while let c = peek(), c.isNumber { s.append(c); i += 1 }
        }
        guard let d = Decimal(string: s, locale: nil) else { throw fail("bad number \(s)") }
        return d
    }

    /// True when the previous tokens are `<row or column> :` — the next bare number / letters close that range.
    private func closesRange(_ check: (FormulaParser.Token) -> Bool) -> Bool {
        guard tokens.count >= 2, tokens[tokens.count - 1] == .colon else { return false }
        return check(tokens[tokens.count - 2])
    }

    /// `1:1`, `$2:$5` — whole rows. Only when the digits are followed by ":" and more digits, or close such a range.
    private mutating func lexRowRange() -> FormulaParser.Token? {
        var j = i, abs = false
        if chars[j] == "$" { abs = true; j += 1 }
        var digits = ""
        while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
        guard !digits.isEmpty, let n = Int(digits), n >= 1 else { return nil }
        let closing = closesRange { if case .row = $0 { return true }; return false } && !(j < chars.count && (chars[j] == "." || chars[j].isLetter))
        if !closing {
            guard j < chars.count, chars[j] == ":" else { return nil }
            var k = j + 1
            if k < chars.count, chars[k] == "$" { k += 1 }
            guard k < chars.count, chars[k].isNumber else { return nil }
        }
        i = j
        return .row(n - 1, sheet: nil, abs: abs)
    }

    /// A sheet-qualified or bare reference, whole column, name or function.
    private mutating func lexReferenceLike() throws {
        var sheet: String? = nil
        let start = i
        if peek() == "'" {
            i += 1
            var name = ""
            while let c = peek() {
                if c == "'" { if peek(1) == "'" { name.append("'"); i += 2; continue }; i += 1; break }
                name.append(c); i += 1
            }
            guard peek() == "!" else { throw fail("quoted sheet name must be followed by !") }
            i += 1
            sheet = name
        } else {
            // unquoted sheet prefix: identifier-ish characters (incl. "[1]" external workbook markers) up to "!"
            var j = i, name = ""
            if chars[j] == "[" { while j < chars.count, chars[j] != "]" { name.append(chars[j]); j += 1 }; if j < chars.count { name.append("]"); j += 1 } }
            while j < chars.count, FormulaLexer.isIdentChar(chars[j]) { name.append(chars[j]); j += 1 }
            if j < chars.count, chars[j] == "!", !name.isEmpty { sheet = name; i = j + 1 }
        }
        // after an optional sheet prefix: cell ref / column / row / name / function
        if let row = lexRowRange() {
            if case .row(let r, _, let a) = row { tokens.append(.row(r, sheet: sheet, abs: a)) }
            return
        }
        if let t = lexCellOrColumn(sheet: sheet) { tokens.append(t); return }
        var ident = ""
        while let c = peek(), FormulaLexer.isIdentChar(c) { ident.append(c); i += 1 }
        guard !ident.isEmpty else { throw fail("expected a reference or name at \(start)") }
        if peek() == "(" && sheet == nil { tokens.append(.function(ident)); return }
        if peek() == "[" {   // structured reference Table1[Column] — kept as text
            var depth = 0
            while let c = peek() {
                ident.append(c); i += 1
                if c == "[" { depth += 1 } else if c == "]" { depth -= 1; if depth == 0 { break } }
            }
        }
        tokens.append(.name(ident, sheet: sheet))
    }

    /// `$A$1`, `AB12`, or a whole column `A:A` / `$B:$D` (only when followed by ":" and another column).
    private mutating func lexCellOrColumn(sheet: String?) -> FormulaParser.Token? {
        var j = i, absCol = false, absRow = false, letters = "", digits = ""
        if j < chars.count, chars[j] == "$" { absCol = true; j += 1 }
        while j < chars.count, chars[j].isLetter, chars[j].isASCII, letters.count < 3 { letters.append(chars[j]); j += 1 }
        guard !letters.isEmpty else { return nil }
        if j < chars.count, chars[j] == "$" { absRow = true; j += 1 }
        while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
        let followedByIdent = j < chars.count && (FormulaLexer.isIdentChar(chars[j]) || chars[j] == "(")
        if !digits.isEmpty, !followedByIdent, let col = CellRef.columnIndex(letters), let row = Int(digits), row >= 1, col <= CellRef.maxParsedCol {
            i = j
            return .ref(CellRef(row: row - 1, col: col), sheet: sheet, absRow: absRow, absCol: absCol)
        }
        if digits.isEmpty, !absRow, closesRange({ if case .column = $0 { return true }; return false }), !followedByIdent, let col = CellRef.columnIndex(letters) {
            i = j
            return .column(col, sheet: sheet, abs: absCol)
        }
        if digits.isEmpty, !absRow, j < chars.count, chars[j] == ":" {
            // column range: the part after ":" must also be a bare column
            var k = j + 1
            if k < chars.count, chars[k] == "$" { k += 1 }
            var l2 = ""
            while k < chars.count, chars[k].isLetter, chars[k].isASCII, l2.count < 3 { l2.append(chars[k]); k += 1 }
            let nextIsRef = k < chars.count && (chars[k].isNumber || FormulaLexer.isIdentChar(chars[k]))
            if !l2.isEmpty, !nextIsRef, let col = CellRef.columnIndex(letters) {
                i = j
                return .column(col, sheet: sheet, abs: absCol)
            }
        }
        return nil
    }

    /// ODS `[.A1]`, `[.A1:.B2]`, `[Sheet.A1]`, `['Sheet 1'.$A$1:.B2]`, `[$Sheet.A1]`.
    private mutating func lexODSReference() throws {
        i += 1
        var inner = ""
        while let c = peek(), c != "]" { inner.append(c); i += 1 }
        guard peek() == "]" else { throw fail("unterminated [ reference") }
        i += 1
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { throw fail("bad ODS reference \(inner)") }
        var sheet: String? = nil
        for (n, part) in parts.enumerated() {
            var p = Substring(part)
            var partSheet: String? = nil
            if p.hasPrefix("$") { p = p.dropFirst() }
            if p.hasPrefix("'") {
                var name = "", k = p.index(after: p.startIndex)
                while k < p.endIndex {
                    if p[k] == "'" { if p.index(after: k) < p.endIndex, p[p.index(after: k)] == "'" { name.append("'"); k = p.index(k, offsetBy: 2); continue }; k = p.index(after: k); break }
                    name.append(p[k]); k = p.index(after: k)
                }
                partSheet = name; p = p[k...]
            } else if let dot = p.firstIndex(of: ".") {
                let name = String(p[..<dot])
                if !name.isEmpty { partSheet = name }
                p = p[dot...]
            }
            guard p.hasPrefix(".") else { throw fail("ODS reference without . : \(part)") }
            let cell = String(p.dropFirst())
            if n == 0 { sheet = partSheet } else if let ps = partSheet { sheet = ps }
            let absCol = cell.hasPrefix("$")
            let absRow = cell.dropFirst(absCol ? 1 : 0).contains("$")
            if let r = CellRef(cell) { tokens.append(.ref(r, sheet: sheet, absRow: absRow, absCol: absCol)) }
            else if let col = CellRef.columnIndex(cell.replacingOccurrences(of: "$", with: "")) { tokens.append(.column(col, sheet: sheet, abs: absCol)) }
            else if let row = Int(cell.replacingOccurrences(of: "$", with: "")), row >= 1 { tokens.append(.row(row - 1, sheet: sheet, abs: absCol)) }
            else { throw fail("bad ODS cell \(cell)") }
            if n == 0, parts.count == 2 { tokens.append(.colon) }
        }
    }
}

/// Renders a tree in one dialect, adding parentheses only where the parser would otherwise read the text differently.
struct FormulaEmitter {
    let dialect: SheetFormat

    func emit(_ e: FormulaExpr) -> String {
        switch e {
        case .number(let d): return "\(d)"
        case .string(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .boolean(let b): return b ? "TRUE" : "FALSE"
        case .error(let s): return s
        case .ref, .column, .row: return reference(e, omitSheet: nil)
        case .name(let n, let s): return (s.map { sheetPrefix($0) } ?? "") + n
        case .range(let a, let b):
            if dialect == .ods { return "[" + odsEndpoint(a) + ":" + odsEndpoint(b, omitSheet: FormulaExpr.sheetOf(a)) + "]" }
            return reference(a, omitSheet: nil) + ":" + reference(b, omitSheet: FormulaExpr.sheetOf(a))
        case .unary(.percent, let x): return operand(x, under: .percent, rightSide: false) + "%"
        case .unary(let op, let x): return op.symbol + operand(x, under: op, rightSide: true)
        case .binary(.union, let a, let b): return dialect == .ods ? emit(a) + "~" + emit(b) : "(" + emit(a) + "," + emit(b) + ")"
        case .binary(let op, let a, let b): return operand(a, under: op, rightSide: false) + op.symbol + operand(b, under: op, rightSide: true)
        case .call(let name, let args): return name + "(" + args.map(emit).joined(separator: separator) + ")"
        case .array(let rows): return "{" + rows.map { $0.map(emit).joined(separator: dialect == .ods ? ";" : ",") }.joined(separator: dialect == .ods ? "|" : ";") + "}"
        case .missing: return ""
        case .unparsed(let text, _): return text
        }
    }

    private var separator: String { dialect == .ods ? ";" : "," }

    private func operand(_ x: FormulaExpr, under op: FormulaOp, rightSide: Bool) -> String {
        let needsParens: Bool
        switch x {
        case .binary(let inner, _, _) where inner != .union:
            needsParens = rightSide ? inner.precedence <= op.precedence : inner.precedence < op.precedence
        case .unary(let inner, _):
            // -2^2 parses as (-2)^2, so a unary operand under ^ is safe; under % or another unary it is too
            needsParens = inner.precedence < op.precedence
        default: needsParens = false
        }
        return needsParens ? "(" + emit(x) + ")" : emit(x)
    }

    private func sheetPrefix(_ s: String) -> String { CellRef.formulaSheetName(s) + "!" }

    private func reference(_ e: FormulaExpr, omitSheet: String?) -> String {
        if dialect == .ods { return "[" + odsEndpoint(e) + "]" }
        switch e {
        case .ref(let r, let s, let ar, let ac):
            let prefix = s != nil && s != omitSheet ? sheetPrefix(s!) : ""
            return prefix + (ac ? "$" : "") + r.columnName + (ar ? "$" : "") + String(r.row + 1)
        case .column(let c, let s, let a): return (s != nil && s != omitSheet ? sheetPrefix(s!) : "") + (a ? "$" : "") + CellRef.columnName(c)
        case .row(let r, let s, let a): return (s != nil && s != omitSheet ? sheetPrefix(s!) : "") + (a ? "$" : "") + String(r + 1)
        default: return emit(e)
        }
    }

    /// `.A1`, `$Sheet.A1`, `'My Sheet'.$A$1` — the inside of an ODS bracket.
    private func odsEndpoint(_ e: FormulaExpr, omitSheet: String? = nil) -> String {
        func prefix(_ s: String?) -> String {
            guard let s, s != omitSheet else { return "." }
            let simple = s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            return (simple ? s : "'" + s.replacingOccurrences(of: "'", with: "''") + "'") + "."
        }
        switch e {
        case .ref(let r, let s, let ar, let ac): return prefix(s) + (ac ? "$" : "") + r.columnName + (ar ? "$" : "") + String(r.row + 1)
        case .column(let c, let s, let a): return prefix(s) + (a ? "$" : "") + CellRef.columnName(c)
        case .row(let r, let s, let a): return prefix(s) + (a ? "$" : "") + String(r + 1)
        default: return emit(e)
        }
    }
}
