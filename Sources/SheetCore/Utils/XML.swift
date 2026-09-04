import Foundation
#if canImport(FoundationXML)
import FoundationXML   // where Foundation is split, the XML parser lives in its own module
#endif

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

    /// Parses an entry as it is expanded, piece by piece (spec Appendix B.39.8).
    @discardableResult
    package func run(stream: ZipEntryStream, part: String) throws -> Int {
        let d = SAXDriver(handler: self)
        driver = d
        defer { driver = nil }
        try d.run(stream: stream, part: part)
        return d.largestCarry
    }
    package func fail(_ error: SheetError) { driver?.fail(error) }
}

/// Foundation `XMLParser` → `SAXHandler` events, with subtree capture.
package final class SAXDriver: NSObject, XMLParserDelegate {
    unowned let handler: SAXHandler
    private(set) var failure: SheetError?
    private weak var parser: XMLParser?
    private var currentQualifiedName = ""
    private var currentAttributes: [String: String] = [:]
    private(set) var captureDepth = 0
    private var captureBuffer = ""
    private var captureElement = ""
    private var openTagPending = false
    private var deliverWhileCapturing = false
    private var sawRoot = false

    package init(handler: SAXHandler) { self.handler = handler }

    /// Which tokenizer turns the bytes into events. `.automatic` is the byte scanner for UTF-8 parts and
    /// Foundation's parser for the rest; the other two exist so a test can put the same part through both.
    package enum Engine { case automatic, scanner, foundation }

    package func run(_ data: Data, part: String, engine: Engine = .automatic) throws {
        try SAXDriver.rejectUndecodableBytes(data, part: part)
        var useScanner: Bool
        switch engine {
        case .scanner: useScanner = true
        case .foundation: useScanner = false
        case .automatic:
            #if SWIFTSHEETS_FOUNDATION_XML
            useScanner = false
            #else
            // a part in UTF-16, or naming another encoding, is Foundation's to decode
            if let (encoding, _) = TextEncodingSniffer.bom(in: data), encoding != .utf8 { useScanner = false }
            else { useScanner = !SAXDriver.declaresOtherEncoding(data) }
            #endif
        }
        if useScanner {
            try runScanner(data, part: part)
            return
        }
        let parser = XMLParser(data: data)
        self.parser = parser
        parser.shouldProcessNamespaces = false
        parser.delegate = self
        let ok = parser.parse()
        if let failure { throw failure }
        guard ok else { throw SheetError.malformedPart(path: part, detail: parser.parserError?.localizedDescription ?? "parse error") }
    }

    // MARK: - A part read in pieces

    /// Parses an entry as it is expanded, piece by piece, never holding more of it than the piece in hand plus
    /// whatever token or preserved subtree straddles a boundary (spec Appendix B.39.8). The first piece decides
    /// the engine; a part Foundation has to read is gathered whole for it.
    package func run(stream: ZipEntryStream, part: String) throws {
        let feeder = try PieceFeeder(driver: self, stream: stream, part: part)
        while try feeder.feedNext() {}
        if let failure { throw failure }
    }

    /// The same, one piece at a time: `feedNext` expands the next piece and delivers its events, and answers
    /// false once the part is exhausted or the handler has stopped the walk. What a lazy row sequence pulls on.
    package final class PieceFeeder {
        private let driver: SAXDriver
        private let stream: ZipEntryStream
        private let part: String
        private var scanner: XMLScanner?
        private var carry: [UInt8] = []
        private var scanned = 0            // bytes of `carry` already turned into events (kept only for an open capture)
        private var offset = 0             // bytes of the part before `carry`
        private var final = false
        private var checkedUpTo = 0        // bytes of `carry` already checked for UTF-8
        private var done = false

        package init(driver: SAXDriver, stream: ZipEntryStream, part: String) throws {
            self.driver = driver; self.stream = stream; self.part = part
            if let first = try stream.next() { carry.append(contentsOf: first) }
            let head = Data(carry.prefix(256))
            var useScanner = true
            #if SWIFTSHEETS_FOUNDATION_XML
            useScanner = false
            #else
            if let (encoding, _) = TextEncodingSniffer.bom(in: head), encoding != .utf8 { useScanner = false }
            else if SAXDriver.declaresOtherEncoding(head) { useScanner = false }
            #endif
            if useScanner {
                scanner = XMLScanner(handler: driver.handler, driver: driver, part: part)
                final = carry.isEmpty
            }
        }

        package func feedNext() throws -> Bool {
            guard !done else { return false }
            guard let scanner else {
                // Foundation's parser takes the whole part at once
                var whole = Data(carry)
                while let piece = try stream.next() { whole.append(piece) }
                done = true
                do {
                    try driver.run(whole, part: part, engine: .foundation)
                } catch {
                    // a stop the handler asked for is reported through `failure`, as the scanner path does;
                    // anything else is the parser's own verdict
                    guard driver.failure != nil else { throw error }
                }
                return false
            }
            if !final, let piece = try stream.next() { carry.append(contentsOf: piece) } else { final = true }
            driver.largestCarry = Swift.max(driver.largestCarry, carry.count)
            // UTF-8 is checked as the bytes arrive; a sequence cut by a piece boundary waits for the next piece
            try SAXDriver.checkUTF8(carry, from: checkedUpTo, final: final, offset: offset, part: part)
            checkedUpTo = Swift.max(0, carry.count - 3)
            let consumed = try carry.withUnsafeBufferPointer { b -> Int in
                driver.scannerBuffer = b
                defer { driver.scannerBuffer = nil }
                return try scanner.feed(b, startingAt: scanned, final: final)
            }
            if driver.stopped || final { done = true; return false }
            var keep = consumed
            if driver.captureDepth > 0 { keep = Swift.min(keep, driver.captureStart) }
            carry.removeFirst(keep)
            scanned = consumed - keep
            driver.captureStart -= keep
            driver.currentTagStart -= keep
            checkedUpTo = Swift.max(0, checkedUpTo - keep)
            scanner.advance(by: keep)
            offset += keep
            return true
        }

        /// The failure the handler raised, if any, once the walk has stopped.
        package var failure: SheetError? { driver.failure }
    }

    /// `rejectUndecodableBytes` for a part arriving in pieces: the bytes from `from` on are checked, and an
    /// incomplete sequence at the very end is only a fault when nothing more is coming.
    static func checkUTF8(_ bytes: [UInt8], from: Int, final: Bool, offset: Int, part: String) throws {
        guard from < bytes.count else { return }
        let bad: Int? = bytes.withUnsafeBufferPointer { b in
            TextEncodingSniffer.firstInvalidUTF8Offset(in: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: b[from...])))
        }
        guard let bad else { return }
        let at = from + bad
        if !final, at >= bytes.count - 3 { return }
        throw SheetError.malformedPart(path: part, detail: "byte \(offset + at) is not valid UTF-8")
    }

    // MARK: - The byte scanner's side

    /// Set by `fail` while the scanner runs: it stops at the next event.
    package private(set) var stopped = false
    /// The most bytes of a part held at once while it was read in pieces — what a test can hold the reader to.
    package internal(set) var largestCarry = 0
    var scannerBuffer: UnsafeBufferPointer<UInt8>?
    var currentTagStart = 0
    var captureStart = 0

    private func runScanner(_ data: Data, part: String) throws {
        try data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            scannerBuffer = b
            defer { scannerBuffer = nil }
            try XMLScanner(handler: handler, driver: self, part: part).run(b)
        }
        if let failure { throw failure }
    }

    func scannerStart(qualified: String, attributes: [String: String], tagStart: Int, tagEnd: Int) throws {
        if captureDepth > 0 {
            captureDepth += 1
            if deliverWhileCapturing { handler.start(XML.local(qualified), attributes) }
            return
        }
        currentQualifiedName = qualified
        currentTagStart = tagStart
        handler.start(XML.local(qualified), attributes)
    }

    func scannerText(_ s: String) {
        if captureDepth > 0 { if deliverWhileCapturing { handler.text(s) } } else { handler.text(s) }
    }

    func scannerEnd(qualified: String, tagEnd: Int) throws {
        if captureDepth > 0 {
            captureDepth -= 1
            let deliver = deliverWhileCapturing
            if captureDepth == 0 {
                // the subtree exactly as the file has it: the bytes from its '<' to the end of its end tag
                let xml = String(decoding: UnsafeBufferPointer(rebasing: scannerBuffer![captureStart..<tagEnd]), as: UTF8.self)
                let fragment = XMLFragment(element: XML.local(captureElement), xml: xml)
                deliverWhileCapturing = false
                if deliver { handler.end(XML.local(qualified)) }
                handler.captured(fragment)
            } else if deliver {
                handler.end(XML.local(qualified))
            }
            return
        }
        handler.end(XML.local(qualified))
    }

    /// XML whose bytes are not valid UTF-8 is a malformed part, and never reaches the parser.
    ///
    /// This is not tidiness. Where Foundation's parser is the one built on libxml2, an element name carrying
    /// bytes that are not valid UTF-8 takes the **process** down — not the read, the process — while it turns
    /// that name into a `String`. A caller must not lose their program over someone else's broken file, and
    /// "this part is malformed" is what this library already promises to say. The specimen that found it is in
    /// `Fixtures/malformed/content-types-invalid-utf8.xlsx`: four bytes of a byte-flipped download landing
    /// inside the word `Default`.
    ///
    /// A part that says it is something other than UTF-8 — by a byte-order mark, or by naming an encoding in
    /// its XML declaration — is handed over untouched, **when the parser knows the name**: it decodes those
    /// itself, and this question does not apply to them. A name it does not know is another matter. libxml2
    /// reports an unsupported encoding and, run in recovery mode as Foundation runs it, carries on with the
    /// bytes as they are — which puts the trap right back for any name among them that is not UTF-8. So the
    /// exemption is `decodableEncodings`, and a stranger is a malformed part before the parser sees it.
    /// A declaration naming UTF-16 or UTF-32 on bytes that have no byte-order mark and read as 8-bit text is
    /// no encoding at all: the parser reads such a part as UTF-8, and so it is checked as UTF-8.
    ///
    /// Reported upstream as swiftlang/swift-corelibs-foundation#5536 (2026-09-01). This check stays either way:
    /// a machine with an older Swift on it will keep the fault long after the fix lands.
    static func rejectUndecodableBytes(_ data: Data, part: String) throws {
        var body = data
        if let (encoding, length) = TextEncodingSniffer.bom(in: data) {
            guard encoding == .utf8 else { return }
            body = data.dropFirst(length)
        }
        if let declared = declaredEncoding(body), declared != "utf-8", declared != "utf8" {
            if decodableEncodings.contains(declared) { return }
            guard wideEncodings.contains(declared) else {
                throw SheetError.malformedPart(path: part, detail: "encoding \"\(declared)\" is not one this library can decode")
            }
        }
        guard let bad = TextEncodingSniffer.firstInvalidUTF8Offset(in: body) else { return }
        throw SheetError.malformedPart(path: part, detail: "byte \(bad + (data.count - body.count)) is not valid UTF-8")
    }

    /// The 8-bit encodings a part may name in its declaration and be handed to the parser as it is: the ones
    /// libxml2 decodes on every platform this library is tested on (spec Appendix B.38). Any other name is
    /// refused before the parser sees it.
    static let decodableEncodings: Set<String> = [
        "us-ascii", "ascii", "latin1",
        "iso-8859-1", "iso-8859-2", "iso-8859-3", "iso-8859-4", "iso-8859-5", "iso-8859-6", "iso-8859-7",
        "iso-8859-8", "iso-8859-9", "iso-8859-10", "iso-8859-11", "iso-8859-13", "iso-8859-14", "iso-8859-15",
        "iso-8859-16",
        "windows-1250", "windows-1251", "windows-1252", "windows-1253", "windows-1254", "windows-1255",
        "windows-1256", "windows-1257", "windows-1258",
        "shift_jis", "shift-jis", "sjis", "euc-jp", "iso-2022-jp", "euc-kr", "gb2312", "gbk", "gb18030", "big5",
        "koi8-r",
    ]

    /// Names of 16- and 32-bit encodings. A part actually in one of them announces it with a byte-order mark
    /// and never reaches the declaration check; the names matter only on 8-bit bytes, where they are a lie.
    static let wideEncodings: Set<String> = ["utf-16", "utf-16le", "utf-16be", "ucs-2", "utf-32", "utf-32le", "utf-32be", "ucs-4"]

    /// The encoding the XML declaration names, lowercased; nil when there is no declaration or it names none.
    static func declaredEncoding(_ data: Data) -> String? {
        // the declaration is the first thing in the part and is short; bad bytes further in cannot affect it
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        guard head.hasPrefix("<?xml"), let close = head.range(of: "?>"),
              let key = head.range(of: "encoding="), key.upperBound < close.lowerBound else { return nil }
        let rest = head[key.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        return rest.dropFirst().prefix { $0 != quote }.lowercased()
    }

    /// True when the XML declaration names an encoding that is not UTF-8.
    static func declaresOtherEncoding(_ data: Data) -> Bool {
        declaredEncoding(data).map { $0 != "utf-8" } ?? false
    }

    /// Aborts parsing; `run` rethrows the error (hooks cannot throw).
    package func fail(_ error: SheetError) {
        failure = error
        stopped = true
        parser?.abortParsing()
    }

    /// Call from `start` to keep the element being started (and everything inside it) as raw XML. With
    /// `deliveringEvents`, the handler still receives the subtree's events (parse *and* preserve).
    package func beginCapture(deliveringEvents: Bool = false) {
        captureDepth = 1
        captureElement = currentQualifiedName
        deliverWhileCapturing = deliveringEvents
        if scannerBuffer != nil {
            captureStart = currentTagStart
        } else {
            captureBuffer = ""
            openTag(currentQualifiedName, currentAttributes)
        }
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

/// The attributes of an element a writer builds itself **plus** the source file's own attributes it did not model.
///
/// Duplicate attributes are not well-formed XML, so the two lists cannot simply be concatenated: an attribute the
/// writer emits with its own value must win, and the source's copy of it must be left out. Collecting the names
/// actually written — rather than checking them against a hand-kept list — is what keeps the two halves in step
/// when the writer later learns to emit one more (spec Appendix B.22).
package struct RootAttributes {
    private let element: String
    private var namespaces: [(String, String)]
    private var written: [(name: String, value: String)] = []
    private var names: Set<String> = []

    /// `xmlns` maps a prefix ("" for the default namespace) to its URI.
    package init(_ element: String, xmlns: [String: String] = [:]) {
        self.element = element
        self.namespaces = xmlns.sorted { $0.key < $1.key }.map { ($0.key.isEmpty ? "xmlns" : "xmlns:\($0.key)", $0.value) }
    }

    /// Writes an attribute. The first value set for a name is the one that is written.
    package mutating func set(_ name: String, _ value: String?) {
        guard let value, names.insert(name).inserted else { return }
        written.append((name, value))
    }

    /// Adds the source file's own attributes, skipping every name this writer has already set.
    package mutating func fill(from other: [String: String]) {
        for name in other.keys.sorted() { set(name, other[name]) }
    }

    /// The opening tag, attributes in the order they were set.
    package var opened: String {
        var s = "<\(element)"
        for (name, uri) in namespaces { s += " \(name)=\"\(XML.esc(uri))\"" }
        for (name, value) in written { s += " \(name)=\"\(XML.esc(value))\"" }
        return s + ">"
    }
}
