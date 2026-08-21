import Foundation

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
    func run(_ data: Data, part: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        guard parser.parse() else { throw SheetsError(.xml, "\(part): \(parser.parserError?.localizedDescription ?? "parse error")") }
    }
    func start(_ name: String, _ attrs: [String: String]) {}
    func text(_ s: String) {}
    func end(_ name: String) {}

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        start(XML.local(elementName), attributes)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { end(XML.local(elementName)) }
}
