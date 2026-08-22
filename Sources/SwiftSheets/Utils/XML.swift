import Foundation

/// OOXML's `_xHHHH_` escaping for control characters (openpyxl.utils.escape). Mirrors the reference exactly: `escape`
/// encodes U+0001…U+0019, `unescape` decodes any `_xHHHH_`.
public enum OOXMLEscape {
    public static func escape(_ value: String) -> String {
        var out = ""
        for ch in value.unicodeScalars {
            if ch.value >= 1, ch.value <= 25 { out += String(format: "_x%04x_", ch.value) } else { out.unicodeScalars.append(ch) }
        }
        return out
    }

    public static func unescape(_ value: String) -> String {
        guard value.contains("_x") else { return value }
        var out = "", rest = Substring(value)
        while let r = rest.range(of: "_x") {
            out += rest[..<r.lowerBound]
            let hexStart = r.upperBound
            if let hexEnd = rest.index(hexStart, offsetBy: 4, limitedBy: rest.endIndex), hexEnd < rest.endIndex, rest[hexEnd] == "_",
               let code = UInt32(rest[hexStart..<hexEnd], radix: 16), let scalar = UnicodeScalar(code) {
                out.unicodeScalars.append(scalar); rest = rest[rest.index(after: hexEnd)...]
            } else { out += "_x"; rest = rest[hexStart...] }
        }
        return out + rest
    }
}

enum XML {
    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\t", "\r": out.unicodeScalars.append(ch)
            case let c where c.value < 0x20: continue
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func attr(_ name: String, _ value: String?) -> String {
        guard let value else { return "" }
        return " \(name)=\"\(esc(value))\""
    }

    static func attr(_ name: String, _ value: Int?) -> String { attr(name, value.map(String.init)) }
    static func attr(_ name: String, _ flag: Bool) -> String { flag ? " \(name)=\"1\"" : "" }
    static func num(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : "\(d)" }

    /// Strips a namespace prefix ("x:si" → "si").
    @inline(__always) static func local(_ qualified: String) -> String {
        if let i = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: i)...]) }
        return qualified
    }
}

/// A tiny SAX driver: subclasses override the three hooks; `run` throws on malformed XML.
class SAXParser: NSObject, XMLParserDelegate {
    private var failure: SheetsError?
    private weak var parser: XMLParser?

    func run(_ data: Data, part: String) throws {
        let parser = XMLParser(data: data)
        self.parser = parser
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        let ok = parser.parse()
        if let failure { throw failure }
        guard ok else { throw SheetsError(.xml, "\(part): \(parser.parserError?.localizedDescription ?? "parse error")") }
    }

    /// Aborts parsing; `run` rethrows the error (hooks cannot throw).
    func fail(_ error: SheetsError) { failure = error; parser?.abortParsing() }
    func start(_ name: String, _ attrs: [String: String]) {}
    func text(_ s: String) {}
    func end(_ name: String) {}

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        start(XML.local(elementName), attributes)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { end(XML.local(elementName)) }
}
