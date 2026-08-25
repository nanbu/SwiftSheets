import Foundation
import SheetCore

/// An ODF data style (`number:number-style`, `number:date-style`, …) as a token list, convertible to and from an
/// Excel number-format code. One structure serves both directions so a format that survives the trip one way
/// survives it the other way too. Cases that have no Excel equivalent (or the reverse) are reported as `nil`, and
/// the codecs turn that into a `degraded` / `substituted` warning.
struct ODSDataStyle: Hashable {
    enum Kind: String, Hashable {
        case number = "number-style", percentage = "percentage-style", currency = "currency-style"
        case date = "date-style", time = "time-style", boolean = "boolean-style", text = "text-style"
    }
    enum Item: Hashable {
        case number(decimals: Int, minDecimals: Int, minInteger: Int, grouping: Bool)
        case scientific(decimals: Int, minInteger: Int, exponentDigits: Int)
        case text(String)
        /// `number:currency-symbol` — the thing that makes a data style a *currency* style rather than a number
        /// one, which is how ODF (and every application reading it) knows the cell holds money.
        case currencySymbol(String)
        case year(long: Bool)
        case month(long: Bool, textual: Bool)
        case day(long: Bool)
        case dayOfWeek(long: Bool)
        case hours(long: Bool)
        case minutes(long: Bool)
        case seconds(long: Bool, decimals: Int)
        case amPm
        case boolean
        case textContent
        /// era, quarter, week-of-year, fraction, embedded text … — nothing Excel's codes express the same way.
        case unsupported(String)
    }

    var kind: Kind
    var items: [Item] = []
    /// `number:truncate-on-overflow="false"` — elapsed hours (`[h]:mm:ss`).
    var truncateOnOverflow = true
    /// A `style:map` child (conditional sections) — not mapped.
    var hasMap = false

    // MARK: - Data style → Excel code (reading)

    /// Characters Excel accepts unquoted in date / time codes.
    private static let safeSeparators = Set(" -/:.,()")

    /// The Excel code, or nil when the style has no faithful Excel form.
    var excelCode: String? {
        guard !hasMap else { return nil }
        switch kind {
        case .boolean: return NumberFormat.general
        case .text: return NumberFormat.text
        case .date, .time: return dateCode
        case .number, .percentage, .currency: return numberCode
        }
    }

    private var numberCode: String? {
        var out = ""
        var sawNumber = false
        for item in items {
            switch item {
            case .number(let decimals, let minDecimals, let minInteger, let grouping):
                guard !sawNumber else { return nil }
                sawNumber = true
                out += ODSDataStyle.integerPattern(minInteger: minInteger, grouping: grouping)
                if decimals > 0 { out += "." + String(repeating: "0", count: Swift.min(minDecimals, decimals)) + String(repeating: "#", count: Swift.max(0, decimals - minDecimals)) }
            case .scientific(let decimals, let minInteger, let exponentDigits):
                guard !sawNumber else { return nil }
                sawNumber = true
                out += ODSDataStyle.integerPattern(minInteger: minInteger, grouping: false)
                if decimals > 0 { out += "." + String(repeating: "0", count: decimals) }
                out += "E+" + String(repeating: "0", count: Swift.max(1, exponentDigits))
            case .currencySymbol(let symbol):
                // always the `[$…]` form, so that writing the code back out makes a currency style again rather
                // than a plain number one with a symbol in front of it. Excel's locale tag (`[$¥-411]`) has no ODF
                // equivalent and is not carried, so a round trip normalises it away.
                out += "[$\(symbol)]"
            case .text(let t):
                if kind == .percentage, t == "%" { out += "%" }
                else if t == " " || t == "-" { out += t }
                else if !t.isEmpty { out += "\"" + t.replacingOccurrences(of: "\"", with: "") + "\"" }
            default: return nil
            }
        }
        return sawNumber ? out : nil
    }

    private static func integerPattern(minInteger: Int, grouping: Bool) -> String {
        let digits = minInteger <= 0 ? "#" : String(repeating: "0", count: minInteger)
        return grouping ? "#,##" + digits : digits
    }

    private var dateCode: String? {
        var out = ""
        for item in items {
            switch item {
            case .year(let long): out += long ? "yyyy" : "yy"
            case .month(let long, let textual): out += textual ? (long ? "mmmm" : "mmm") : (long ? "mm" : "m")
            case .day(let long): out += long ? "dd" : "d"
            case .dayOfWeek(let long): out += long ? "dddd" : "ddd"
            case .hours(let long): out += truncateOnOverflow ? (long ? "hh" : "h") : (long ? "[hh]" : "[h]")
            case .minutes(let long): out += long ? "mm" : "m"
            case .seconds(let long, let decimals): out += (long ? "ss" : "s") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
            case .amPm: out += "AM/PM"
            case .text(let t):
                guard !t.isEmpty else { continue }
                out += t.allSatisfy({ ODSDataStyle.safeSeparators.contains($0) }) ? t : "\"" + t.replacingOccurrences(of: "\"", with: "") + "\""
            default: return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Excel code → data style (writing)

    /// The data style for an Excel code. `.general` needs none (nil style, exact). A code with several sections
    /// keeps its first section only (`exact == false`); a code with no ODF form yields a nil style.
    static func from(excelCode code: String) -> (style: ODSDataStyle?, exact: Bool) {
        if code == NumberFormat.general || code.isEmpty { return (nil, true) }
        if code == NumberFormat.text { return (ODSDataStyle(kind: .text, items: [.textContent]), true) }
        let sections = splitSections(code)
        guard let first = sections.first, !first.isEmpty else { return (nil, false) }
        let exact = sections.count == 1
        if NumberFormat.isDateFormat(first) { return (dateStyle(first), exact) }
        return (numberStyle(first), exact)
    }

    /// Splits on `;` outside quotes and brackets.
    private static func splitSections(_ code: String) -> [String] {
        var sections: [String] = [""], inQuote = false, inBracket = false
        for ch in code {
            if ch == "\"" { inQuote.toggle() }
            else if !inQuote, ch == "[" { inBracket = true }
            else if !inQuote, ch == "]" { inBracket = false }
            if ch == ";", !inQuote, !inBracket { sections.append(""); continue }
            sections[sections.count - 1].append(ch)
        }
        return sections
    }

    private enum Piece { case literal(String), currency(String), elapsed(Character, Int), unit(Character, Int), amPm, secondsDecimals(Int), core(String), bad }

    /// Lexes a format section into literals, date units and numeric core characters.
    private static func lex(_ s: String) -> [Piece] {
        let chars = Array(s)
        var pieces: [Piece] = []
        var i = 0
        var core = ""
        func flushCore() { if !core.isEmpty { pieces.append(.core(core)); core = "" } }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                flushCore()
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                pieces.append(.literal(text)); i = j + 1
            case "\\":
                flushCore()
                if i + 1 < chars.count { pieces.append(.literal(String(chars[i + 1]))) }
                i += 2
            case "_":
                flushCore(); pieces.append(.literal(" ")); i += 2
            case "*":
                flushCore(); i += 2
            case "[":
                flushCore()
                var j = i + 1, inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                i = j + 1
                let lower = inner.lowercased()
                if ["h", "hh", "m", "mm", "s", "ss"].contains(lower) { pieces.append(.elapsed(lower.first!, lower.count)) }
                else if inner.hasPrefix("$") {
                    // [$¥-411] — currency symbol with a locale tag
                    let body = inner.dropFirst()
                    let symbol = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if !symbol.isEmpty { pieces.append(.currency(symbol)) }
                }
                // colours ([Red], [Color 3]) and conditions are dropped
            case "A", "a":
                flushCore()
                let rest = String(chars[i...]).uppercased()
                if rest.hasPrefix("AM/PM") { pieces.append(.amPm); i += 5 }
                else if rest.hasPrefix("A/P") { pieces.append(.amPm); i += 3 }
                else { pieces.append(.bad); i += 1 }
            case "y", "Y", "m", "M", "d", "D", "h", "H", "s", "S":
                flushCore()
                let unit = Character(c.lowercased())
                var j = i
                while j < chars.count, chars[j].lowercased() == String(unit) { j += 1 }
                pieces.append(.unit(unit, j - i))
                i = j
                if unit == "s", i < chars.count, chars[i] == ".", i + 1 < chars.count, chars[i + 1] == "0" {
                    var k = i + 1
                    while k < chars.count, chars[k] == "0" { k += 1 }
                    pieces.append(.secondsDecimals(k - i - 1)); i = k
                }
            case "#", "0", "?", ",", ".", "%", "E", "e", "+", "-", "/":
                if (c == "-" || c == "/" || c == ".") && core.isEmpty && !pieces.contains(where: { if case .core = $0 { return true }; return false }) {
                    // a separator before any digits: literal (date-style "-" / "/" or a leading "-")
                    pieces.append(.literal(String(c))); i += 1
                } else if c == "-" || c == "/" {
                    // after the digits: a literal unless it continues E- (handled below)
                    if c == "-", core.hasSuffix("E") || core.hasSuffix("e") { core.append(c) } else { flushCore(); pieces.append(.literal(String(c))) }
                    i += 1
                } else { core.append(c); i += 1 }
            case ":", " ", "(", ")":
                flushCore(); pieces.append(.literal(String(c))); i += 1
            case "@":
                flushCore(); pieces.append(.bad); i += 1
            default:
                flushCore(); pieces.append(.literal(String(c))); i += 1
            }
        }
        flushCore()
        return pieces
    }

    private static func dateStyle(_ s: String) -> ODSDataStyle? {
        let pieces = lex(s)
        var units: [(Character, Int, Bool)] = []   // unit, count, elapsed — in order, for minute disambiguation
        for p in pieces {
            switch p {
            case .unit(let u, let n): units.append((u, n, false))
            case .elapsed(let u, let n): units.append((u, n, true))
            default: break
            }
        }
        var unitIndex = 0
        var style = ODSDataStyle(kind: .time)
        var hasDatePart = false
        for p in pieces {
            switch p {
            case .literal(let t): style.items.append(.text(t))
            case .currency: return nil                  // a date style with a currency symbol is not a date style
            case .amPm: style.items.append(.amPm)
            case .secondsDecimals(let n):
                guard case .seconds(let long, _)? = style.items.last else { return nil }
                style.items[style.items.count - 1] = .seconds(long: long, decimals: n)
            case .unit(let u, let n), .elapsed(let u, let n):
                let elapsed: Bool = { if case .elapsed = p { return true }; return false }()
                let isMinutes: Bool = {
                    guard u == "m" else { return false }
                    if elapsed || n > 2 { return elapsed }
                    let prev = unitIndex > 0 ? units[unitIndex - 1].0 : nil
                    let next = unitIndex + 1 < units.count ? units[unitIndex + 1].0 : nil
                    return prev == "h" || next == "s"
                }()
                unitIndex += 1
                if elapsed { style.truncateOnOverflow = false }
                switch u {
                case "y": style.items.append(.year(long: n >= 4)); hasDatePart = true
                case "d":
                    style.items.append(n >= 3 ? .dayOfWeek(long: n >= 4) : .day(long: n == 2)); hasDatePart = true
                case "h": style.items.append(.hours(long: n >= 2))
                case "s": style.items.append(.seconds(long: n >= 2, decimals: 0))
                case "m":
                    if isMinutes { style.items.append(.minutes(long: n >= 2)) }
                    else { style.items.append(.month(long: n == 2 || n >= 4, textual: n >= 3)); hasDatePart = true }
                default: return nil
                }
            case .core, .bad: return nil
            }
        }
        guard style.items.contains(where: { if case .text = $0 { return false }; return true }) else { return nil }
        style.kind = hasDatePart ? .date : .time
        return style
    }

    private static func numberStyle(_ s: String) -> ODSDataStyle? {
        let pieces = lex(s)
        var style = ODSDataStyle(kind: .number)
        var sawCore = false
        for p in pieces {
            switch p {
            case .literal(let t): style.items.append(.text(t))
            case .currency(let symbol):
                // a currency symbol is what turns a number style into a currency one
                style.kind = .currency
                style.items.append(.currencySymbol(symbol))
            case .core(let core):
                guard !sawCore else { return nil }
                sawCore = true
                var body = core
                if body.hasSuffix("%") { style.kind = .percentage; body.removeLast() }
                guard !body.contains("?"), !body.contains("/") else { return nil }
                var exponent: String?
                if let e = body.firstIndex(where: { $0 == "E" || $0 == "e" }) {
                    exponent = String(body[body.index(after: e)...]); body = String(body[..<e])
                }
                let parts = body.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { return nil }
                let intPart = String(parts[0]), decPart = parts.count == 2 ? String(parts[1]) : ""
                guard !intPart.hasSuffix(","), !decPart.contains(",") else { return nil }   // trailing commas scale by 1000
                let grouping = intPart.contains(",")
                let minInteger = intPart.filter { $0 == "0" }.count
                let decimals = decPart.count, minDecimals = decPart.filter { $0 == "0" }.count
                if let exponent {
                    let digits = exponent.filter { $0 == "0" }.count
                    guard digits > 0, !grouping else { return nil }
                    style.items.append(.scientific(decimals: decimals, minInteger: minInteger, exponentDigits: digits))
                } else {
                    style.items.append(.number(decimals: decimals, minDecimals: minDecimals, minInteger: minInteger, grouping: grouping))
                }
                if style.kind == .percentage { style.items.append(.text("%")) }
            case .unit, .elapsed, .amPm, .secondsDecimals, .bad: return nil
            }
        }
        return sawCore ? style : nil
    }

    // MARK: - XML

    func xml(name: String) -> String {
        var s = "<number:\(kind.rawValue) style:name=\"\(XML.esc(name))\""
        if !truncateOnOverflow { s += " number:truncate-on-overflow=\"false\"" }
        s += ">"
        for item in items {
            switch item {
            case .number(let decimals, let minDecimals, let minInteger, let grouping):
                s += "<number:number number:decimal-places=\"\(decimals)\" number:min-decimal-places=\"\(minDecimals)\" number:min-integer-digits=\"\(minInteger)\"\(grouping ? " number:grouping=\"true\"" : "")/>"
            case .scientific(let decimals, let minInteger, let exponentDigits):
                s += "<number:scientific-number number:decimal-places=\"\(decimals)\" number:min-decimal-places=\"\(decimals)\" number:min-integer-digits=\"\(minInteger)\" number:min-exponent-digits=\"\(exponentDigits)\" number:forced-exponent-sign=\"true\"/>"
            case .text(let t): s += "<number:text>\(XML.esc(t))</number:text>"
            case .currencySymbol(let symbol): s += "<number:currency-symbol>\(XML.esc(symbol))</number:currency-symbol>"
            case .year(let long): s += "<number:year\(long ? " number:style=\"long\"" : "")/>"
            case .month(let long, let textual): s += "<number:month\(long ? " number:style=\"long\"" : "")\(textual ? " number:textual=\"true\"" : "")/>"
            case .day(let long): s += "<number:day\(long ? " number:style=\"long\"" : "")/>"
            case .dayOfWeek(let long): s += "<number:day-of-week\(long ? " number:style=\"long\"" : "")/>"
            case .hours(let long): s += "<number:hours\(long ? " number:style=\"long\"" : "")/>"
            case .minutes(let long): s += "<number:minutes\(long ? " number:style=\"long\"" : "")/>"
            case .seconds(let long, let decimals): s += "<number:seconds\(long ? " number:style=\"long\"" : "")\(decimals > 0 ? " number:decimal-places=\"\(decimals)\"" : "")/>"
            case .amPm: s += "<number:am-pm/>"
            case .boolean: s += "<number:boolean/>"
            case .textContent: s += "<number:text-content/>"
            case .unsupported: break
            }
        }
        return s + "</number:\(kind.rawValue)>"
    }
}
