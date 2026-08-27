import Foundation

/// A formula as a tree. Dialect differences (argument separators, `[.A1]` vs `A1`, the `=` / `of:=` prefix) are
/// *representation* and live in the parser and the emitters; the tree only carries meaning.
public indirect enum FormulaExpr: Hashable, Sendable {
    case number(Decimal)
    case string(String)
    case boolean(Bool)
    /// "#REF!", "#N/A", …
    case error(String)
    /// A cell, optionally on another sheet. `absRow` / `absCol` are the `$` markers.
    case ref(CellRef, sheet: String? = nil, absRow: Bool = false, absCol: Bool = false)
    /// A whole column (only meaningful as an endpoint of `range`).
    case column(Int, sheet: String? = nil, abs: Bool = false)
    /// A whole row (only meaningful as an endpoint of `range`).
    case row(Int, sheet: String? = nil, abs: Bool = false)
    /// A defined name, or a structured / external reference kept as text.
    case name(String, sheet: String? = nil)
    /// Two references bound with `:`.
    case range(FormulaExpr, FormulaExpr)
    case unary(FormulaOp, FormulaExpr)
    case binary(FormulaOp, FormulaExpr, FormulaExpr)
    case call(name: String, args: [FormulaExpr])
    /// `{1,2;3,4}` — rows of constants.
    case array([[FormulaExpr]])
    /// An omitted argument, as in `SUM(A1,,B1)`.
    case missing
    /// Text the parser could not read, kept verbatim so a same-dialect round trip is lossless.
    case unparsed(String, dialect: SheetFormat)

    /// Parses formula text. A leading `=` (XLSX) or `of:=` / `=` (ODS) is accepted and dropped. Unreadable text
    /// becomes `.unparsed` rather than an error.
    public static func parse(_ text: String, dialect: SheetFormat = .xlsx) -> FormulaExpr {
        let body = FormulaParser.stripPrefix(text, dialect: dialect)
        do { var p = try FormulaParser(body, dialect: dialect); return try p.parseFormula() } catch { return .unparsed(body, dialect: dialect) }
    }

    /// Like `parse` but throws `SheetError.formulaSyntax` instead of falling back to `.unparsed`.
    public static func parseStrict(_ text: String, dialect: SheetFormat = .xlsx) throws -> FormulaExpr {
        var p = try FormulaParser(FormulaParser.stripPrefix(text, dialect: dialect), dialect: dialect)
        return try p.parseFormula()
    }

    /// The formula in a dialect: XLSX text has no prefix (what goes inside `<f>`), ODS text starts with `of:=`.
    /// `.unparsed` renders its original text whatever the dialect (the codec reports the degradation).
    public func rendered(as dialect: SheetFormat) -> String {
        switch dialect {
        case .ods: return "of:=" + FormulaEmitter(dialect: .ods).emit(self)
        default: return FormulaEmitter(dialect: .xlsx).emit(self)
        }
    }

    /// "=SUM(A1:B2)" — the Excel-style text with its `=`.
    public var text: String { "=" + rendered(as: .xlsx) }

    public var isUnparsed: Bool { if case .unparsed = self { return true }; return false }

    /// Whether `rendered(as:)` can write this tree in that dialect without changing what it means.
    ///
    /// One shape fails: OpenFormula writes the intersection operator as `!`, which is also how a sheet-qualified
    /// name is written, so `MyName!Other` reads back as a reference to a sheet called MyName. Excel's spelling —
    /// a space — has no such clash. A writer that meets one degrades to the cached value rather than emitting
    /// something that means something else.
    public func isExpressible(in dialect: SheetFormat) -> Bool {
        guard dialect == .ods else { return true }
        switch self {
        case .binary(.intersect, let a, let b):
            func isName(_ e: FormulaExpr) -> Bool { if case .name = e { return true }; return false }
            return !isName(a) && !isName(b) && a.isExpressible(in: dialect) && b.isExpressible(in: dialect)
        case .range(let a, let b): return a.isExpressible(in: dialect) && b.isExpressible(in: dialect)
        case .unary(_, let e): return e.isExpressible(in: dialect)
        case .binary(_, let a, let b): return a.isExpressible(in: dialect) && b.isExpressible(in: dialect)
        case .call(_, let args): return args.allSatisfy { $0.isExpressible(in: dialect) }
        case .array(let rows): return rows.allSatisfy { $0.allSatisfy { $0.isExpressible(in: dialect) } }
        default: return true
        }
    }

    /// The first stock-or-currency call in the tree, or nil. STOCK, STOCKH, CURRENCY, CURRENCYH,
    /// CURRENCYCONVERT and CURRENCYCODE are Numbers' quote functions: their answers come from Apple's quote
    /// service, not from the sheet. Excel and OpenFormula have no spelling for any of the six, and Numbers'
    /// own Excel export writes the fetched value in their place (measured on 15.3.1 — every other formula in
    /// the same document went out as a formula). Writers to those formats do the same, and use the name this
    /// returns to say which function it was.
    public var remoteDataFunction: String? {
        switch self {
        case .call(let name, let args):
            let upper = name.uppercased()
            if ["STOCK", "STOCKH", "CURRENCY", "CURRENCYH", "CURRENCYCONVERT", "CURRENCYCODE"].contains(upper) {
                return upper
            }
            return args.lazy.compactMap(\.remoteDataFunction).first
        case .range(let a, let b), .binary(_, let a, let b):
            return a.remoteDataFunction ?? b.remoteDataFunction
        case .unary(_, let e): return e.remoteDataFunction
        case .array(let rows): return rows.lazy.flatMap { $0 }.compactMap(\.remoteDataFunction).first
        default: return nil
        }
    }

    // MARK: - Walking

    /// Rebuilds the tree bottom-up through `transform`.
    public func mapped(_ transform: (FormulaExpr) -> FormulaExpr) -> FormulaExpr {
        let rebuilt: FormulaExpr
        switch self {
        case .range(let a, let b): rebuilt = .range(a.mapped(transform), b.mapped(transform))
        case .unary(let op, let e): rebuilt = .unary(op, e.mapped(transform))
        case .binary(let op, let a, let b): rebuilt = .binary(op, a.mapped(transform), b.mapped(transform))
        case .call(let n, let args): rebuilt = .call(name: n, args: args.map { $0.mapped(transform) })
        case .array(let rows): rebuilt = .array(rows.map { $0.map { $0.mapped(transform) } })
        default: rebuilt = self
        }
        return transform(rebuilt)
    }

    /// Every reference-like leaf, depth first.
    public var references: [FormulaExpr] {
        switch self {
        case .ref, .column, .row: return [self]
        case .range(let a, let b): return a.references + b.references
        case .unary(_, let e): return e.references
        case .binary(_, let a, let b): return a.references + b.references
        case .call(_, let args): return args.flatMap(\.references)
        case .array(let rows): return rows.flatMap { $0.flatMap(\.references) }
        default: return []
        }
    }

    /// The sheet names this formula refers to explicitly.
    public var referencedSheets: Set<String> {
        var out = Set<String>()
        _ = mapped { e in
            switch e {
            case .ref(_, let s, _, _), .column(_, let s, _), .row(_, let s, _), .name(_, let s): if let s { out.insert(s) }
            default: break
            }
            return e
        }
        return out
    }

    // MARK: - Reference maintenance

    /// Sheet references renamed from `old` to `new`.
    public func renamingSheet(_ old: String, to new: String) -> FormulaExpr {
        mapped { e in
            switch e {
            case .ref(let r, let s, let ar, let ac) where s == old: return .ref(r, sheet: new, absRow: ar, absCol: ac)
            case .column(let c, let s, let a) where s == old: return .column(c, sheet: new, abs: a)
            case .row(let r, let s, let a) where s == old: return .row(r, sheet: new, abs: a)
            case .name(let n, let s) where s == old: return .name(n, sheet: new)
            default: return e
            }
        }
    }

    public enum Axis: Sendable { case rows, columns }

    /// References adjusted for rows / columns inserted (`delta > 0`) or deleted (`delta < 0`) at `index` on a sheet.
    /// `onSheet` decides which references move: pass the formula's own sheet name for unqualified references.
    /// A single cell inside a deleted span becomes `#REF!`; a range loses the deleted part (or becomes `#REF!` when
    /// nothing is left) — what Excel does.
    public func shiftingReferences(axis: Axis, at index: Int, delta: Int, onSheet: (String?) -> Bool) -> FormulaExpr {
        guard delta != 0 else { return self }
        func moved(_ v: Int) -> Int? {
            if delta > 0 { return v >= index ? v + delta : v }
            let end = index - delta   // exclusive end of the deleted span
            if v < index { return v }
            if v < end { return nil }
            return v + delta
        }
        func movedEndpoints(_ lo: Int, _ hi: Int) -> (Int, Int)? {
            if delta > 0 { return (moved(lo)!, moved(hi)!) }
            let end = index - delta
            if hi < index || lo >= end { return (moved(lo)!, moved(hi)!) }   // untouched or fully after
            let newLo = lo < index ? lo : index
            let newHi = hi >= end ? hi + delta : index - 1
            return newHi >= newLo ? (newLo, newHi) : nil
        }
        func shiftRef(_ e: FormulaExpr) -> FormulaExpr? {
            switch e {
            case .ref(let r, let s, let ar, let ac) where onSheet(s):
                let v = axis == .rows ? r.row : r.col
                guard let m = moved(v) else { return nil }
                return .ref(axis == .rows ? CellRef(row: m, col: r.col) : CellRef(row: r.row, col: m), sheet: s, absRow: ar, absCol: ac)
            case .column(let c, let s, let a) where onSheet(s) && axis == .columns:
                guard let m = moved(c) else { return nil }
                return .column(m, sheet: s, abs: a)
            case .row(let r, let s, let a) where onSheet(s) && axis == .rows:
                guard let m = moved(r) else { return nil }
                return .row(m, sheet: s, abs: a)
            default: return e
            }
        }
        func go(_ e: FormulaExpr) -> FormulaExpr {
            switch e {
            case .range(let a, let b):
                // shrink rather than invalidate when a deletion cuts through a range
                if delta < 0, let (lo, hi) = FormulaExpr.span(a, b, axis: axis), onSheet(FormulaExpr.sheetOf(a)) {
                    guard let (nlo, nhi) = movedEndpoints(lo, hi) else { return .error("#REF!") }
                    return .range(FormulaExpr.setting(a, axis: axis, to: nlo), FormulaExpr.setting(b, axis: axis, to: nhi))
                }
                guard let na = shiftRef(a), let nb = shiftRef(b) else { return .error("#REF!") }
                return .range(na, nb)
            case .ref, .column, .row: return shiftRef(e) ?? .error("#REF!")
            case .unary(let op, let x): return .unary(op, go(x))
            case .binary(let op, let a, let b): return .binary(op, go(a), go(b))
            case .call(let n, let args): return .call(name: n, args: args.map(go))
            case .array(let rows): return .array(rows.map { $0.map(go) })
            default: return e
            }
        }
        return go(self)
    }

    static func sheetOf(_ e: FormulaExpr) -> String? {
        switch e { case .ref(_, let s, _, _), .column(_, let s, _), .row(_, let s, _): s; default: nil }
    }

    static func span(_ a: FormulaExpr, _ b: FormulaExpr, axis: Axis) -> (Int, Int)? {
        func value(_ e: FormulaExpr) -> Int? {
            switch (e, axis) {
            case (.ref(let r, _, _, _), .rows): return r.row
            case (.ref(let r, _, _, _), .columns): return r.col
            case (.row(let r, _, _), .rows): return r
            case (.column(let c, _, _), .columns): return c
            default: return nil
            }
        }
        guard let x = value(a), let y = value(b) else { return nil }
        return (Swift.min(x, y), Swift.max(x, y))
    }

    static func setting(_ e: FormulaExpr, axis: Axis, to v: Int) -> FormulaExpr {
        switch (e, axis) {
        case (.ref(let r, let s, let ar, let ac), .rows): return .ref(CellRef(row: v, col: r.col), sheet: s, absRow: ar, absCol: ac)
        case (.ref(let r, let s, let ar, let ac), .columns): return .ref(CellRef(row: r.row, col: v), sheet: s, absRow: ar, absCol: ac)
        case (.row(_, let s, let a), .rows): return .row(v, sheet: s, abs: a)
        case (.column(_, let s, let a), .columns): return .column(v, sheet: s, abs: a)
        default: return e
        }
    }
}

/// Operators of the formula language. `symbol` is the XLSX spelling; ODS uses the same symbols.
public enum FormulaOp: Hashable, Sendable, CaseIterable {
    case add, subtract, multiply, divide, power, concat
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    /// Prefix `-` / `+`, postfix `%`.
    case negate, plus, percent
    /// Reference operators: `A1:B2 C1:D2` (space) and `(A1,B2)` (comma inside parentheses).
    case intersect, union

    public var symbol: String {
        switch self {
        case .add, .plus: "+"
        case .subtract, .negate: "-"
        case .multiply: "*"
        case .divide: "/"
        case .power: "^"
        case .concat: "&"
        case .equal: "="
        case .notEqual: "<>"
        case .less: "<"
        case .lessOrEqual: "<="
        case .greater: ">"
        case .greaterOrEqual: ">="
        case .percent: "%"
        case .intersect: " "
        case .union: ","
        }
    }

    /// Binding power (higher binds tighter). Excel: comparison < `&` < `+ -` < `* /` < `^` < `%` < unary < `:`.
    var precedence: Int {
        switch self {
        case .equal, .notEqual, .less, .lessOrEqual, .greater, .greaterOrEqual: 10
        case .concat: 20
        case .add, .subtract: 30
        case .multiply, .divide: 40
        case .power: 50
        case .percent: 60
        case .negate, .plus: 70
        case .union, .intersect: 80
        }
    }
}
