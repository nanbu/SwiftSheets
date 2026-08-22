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

package enum XML {
    package static func esc(_ s: String) -> String {
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

    package static func attr(_ name: String, _ value: String?) -> String {
        guard let value else { return "" }
        return " \(name)=\"\(esc(value))\""
    }

    package static func attr(_ name: String, _ value: Int?) -> String { attr(name, value.map(String.init)) }
    package static func attr(_ name: String, _ flag: Bool) -> String { flag ? " \(name)=\"1\"" : "" }
    package static func num(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : "\(d)" }

    /// Strips a namespace prefix ("x:si" → "si").
    @inline(__always) package static func local(_ qualified: String) -> String {
        if let i = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: i)...]) }
        return qualified
    }
}

/// What a SAX-style parser implements: the three event hooks and, optionally, a receiver for captured subtrees.
/// `run(_:part:)` drives it; from `start` a handler may call `driver?.beginCapture()` to keep the element being
/// started (and everything inside it) as raw XML for round-trip preservation.
package protocol SAXHandler: AnyObject {
    var driver: SAXDriver? { get set }
    /// Attributes of the root element (namespace declarations live here); filled by the driver.
    var rootAttributes: [String: String] { get set }
    func start(_ name: String, _ attrs: [String: String])
    func text(_ s: String)
    func end(_ name: String)
    func captured(_ fragment: XMLFragment)
}

extension SAXHandler {
    package func start(_ name: String, _ attrs: [String: String]) {}
    package func text(_ s: String) {}
    package func end(_ name: String) {}
    package func captured(_ fragment: XMLFragment) {}

    /// Parses `data`, delivering events to this handler. Throws on malformed XML or when the handler called `fail`.
    package func run(_ data: Data, part: String) throws {
        let d = SAXDriver(handler: self)
        driver = d
        defer { driver = nil }
        try d.run(data, part: part)
    }
    package func beginCapture(deliveringEvents: Bool = false) { driver?.beginCapture(deliveringEvents: deliveringEvents) }
    package func fail(_ error: SheetError) { driver?.fail(error) }
}

/// Foundation `XMLParser` → `SAXHandler` events, with subtree capture.
package final class SAXDriver: NSObject, XMLParserDelegate {
    private unowned let handler: SAXHandler
    private var failure: SheetError?
    private weak var parser: XMLParser?
    private var currentQualifiedName = ""
    private var currentAttributes: [String: String] = [:]
    private var captureDepth = 0
    private var captureBuffer = ""
    private var captureElement = ""
    private var openTagPending = false
    private var deliverWhileCapturing = false
    private var sawRoot = false

    package init(handler: SAXHandler) { self.handler = handler }

    package func run(_ data: Data, part: String) throws {
        let parser = XMLParser(data: data)
        self.parser = parser
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        let ok = parser.parse()
        if let failure { throw failure }
        guard ok else { throw SheetError.malformedPart(path: part, detail: parser.parserError?.localizedDescription ?? "parse error") }
    }

    /// Aborts parsing; `run` rethrows the error (hooks cannot throw).
    package func fail(_ error: SheetError) { failure = error; parser?.abortParsing() }

    /// Call from `start` to keep the element being started (and everything inside it) as raw XML. With
    /// `deliveringEvents`, the handler still receives the subtree's events (parse *and* preserve).
    package func beginCapture(deliveringEvents: Bool = false) {
        captureDepth = 1
        captureElement = currentQualifiedName
        captureBuffer = ""
        deliverWhileCapturing = deliveringEvents
        openTag(currentQualifiedName, currentAttributes)
    }

    package var isCapturing: Bool { captureDepth > 0 }

    private func openTag(_ name: String, _ attrs: [String: String]) {
        if openTagPending { captureBuffer += ">" }
        captureBuffer += "<" + name
        for k in attrs.keys.sorted() { captureBuffer += " \(k)=\"\(XML.esc(attrs[k]!))\"" }
        openTagPending = true
    }

    private func appendText(_ s: String) {
        guard !s.isEmpty else { return }
        if openTagPending { captureBuffer += ">"; openTagPending = false }
        captureBuffer += XML.esc(s)
    }

    private func closeTag(_ name: String) {
        if openTagPending { captureBuffer += "/>"; openTagPending = false } else { captureBuffer += "</" + name + ">" }
    }

    package func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if !sawRoot { sawRoot = true; handler.rootAttributes = attributes }
        if captureDepth > 0 {
            captureDepth += 1; openTag(elementName, attributes)
            if deliverWhileCapturing { handler.start(XML.local(elementName), attributes) }
            return
        }
        currentQualifiedName = elementName
        currentAttributes = attributes
        handler.start(XML.local(elementName), attributes)
    }
    package func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureDepth > 0 { appendText(string); if deliverWhileCapturing { handler.text(string) } } else { handler.text(string) }
    }
    package func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        let s = String(decoding: CDATABlock, as: UTF8.self)
        if captureDepth > 0 { appendText(s); if deliverWhileCapturing { handler.text(s) } } else { handler.text(s) }
    }
    package func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if captureDepth > 0 {
            closeTag(elementName)
            captureDepth -= 1
            let deliver = deliverWhileCapturing
            if captureDepth == 0 {
                let fragment = XMLFragment(element: XML.local(captureElement), xml: captureBuffer)
                captureBuffer = ""; deliverWhileCapturing = false
                if deliver { handler.end(XML.local(elementName)) }
                handler.captured(fragment)
            } else if deliver { handler.end(XML.local(elementName)) }
            return
        }
        handler.end(XML.local(elementName))
    }
}
