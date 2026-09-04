import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The byte scanner against Foundation's parser (spec Appendix B.39.6): the same part, the same events. Every
/// XML part of every package in the corpus goes through both, and the two event streams must be identical.
@Suite struct XMLScannerTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    /// Records what a handler is told, in order. Text runs are merged, since how a run is split into calls is
    /// the parser's business, not the handler's.
    final class Recorder: SAXHandler {
        var driver: SAXDriver?
        var rootAttributes: [String: String] = [:]
        enum Event: Equatable { case start(String, [String: String]); case text(String); case end(String); case captured(String, String) }
        var events: [Event] = []
        let captureNames: Set<String>
        let deliverWhileCapturing: Bool
        init(capture: Set<String> = [], delivering: Bool = false) { captureNames = capture; deliverWhileCapturing = delivering }
        func start(_ name: String, _ attrs: [String: String]) {
            events.append(.start(name, attrs))
            if captureNames.contains(name) { beginCapture(deliveringEvents: deliverWhileCapturing) }
        }
        func text(_ s: String) {
            if case .text(let t)? = events.last { events[events.count - 1] = .text(t + s) } else { events.append(.text(s)) }
        }
        func end(_ name: String) { events.append(.end(name)) }
        func captured(_ fragment: XMLFragment) { events.append(.captured(fragment.element, fragment.xml)) }
    }

    /// The first place two event streams part company, described.
    static func firstDifference(_ a: [Recorder.Event], _ b: [Recorder.Event]) -> String {
        for i in 0..<Swift.min(a.count, b.count) where a[i] != b[i] { return "at \(i): foundation \(a[i]) / scanner \(b[i])" }
        return a.count == b.count ? "identical" : "lengths \(a.count) vs \(b.count); tail foundation \(a.suffix(2)) / scanner \(b.suffix(2))"
    }

    static func events(_ data: Data, engine: SAXDriver.Engine, capture: Set<String> = [], delivering: Bool = false) throws -> (Recorder, [Recorder.Event]) {
        let r = Recorder(capture: capture, delivering: delivering)
        let d = SAXDriver(handler: r)
        r.driver = d
        try d.run(data, part: "test.xml", engine: engine)
        return (r, r.events)
    }

    /// Every XML part in every package of the corpus: identical events from both engines.
    @Test func everyPartOfTheCorpusYieldsTheSameEvents() throws {
        let walker = FileManager.default.enumerator(at: Self.fixtures, includingPropertiesForKeys: [.isRegularFileKey])!
        var parts = 0, packages = 0
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            guard ["xlsx", "xlsm", "ods"].contains(ext), let data = try? Data(contentsOf: url), data.count < 2_000_000 else { continue }
            guard let zip = try? ZipArchive(data: data) else { continue }
            packages += 1
            for name in zip.names where name.hasSuffix(".xml") || name.hasSuffix(".rels") || name.hasSuffix(".vml") {
                let part = try zip.read(name)
                // parts Foundation cannot read (encrypted ciphertext, not-UTF-8) are not this test's subject
                guard let (foundation, a) = try? Self.events(part, engine: .foundation) else { continue }
                let (scanner, b) = try Self.events(part, engine: .scanner)
                #expect(a == b, "\(url.lastPathComponent) / \(name): \(Self.firstDifference(a, b))")
                #expect(foundation.rootAttributes == scanner.rootAttributes, "\(url.lastPathComponent) / \(name): root attributes")
                parts += 1
            }
        }
        #expect(packages > 20 && parts > 250, "walked \(packages) packages, \(parts) parts")
        print("XMLScannerTests: walked \(packages) packages, \(parts) parts")
    }

    /// The corners, one by one: entities, character references, CDATA, comments, a DOCTYPE with an internal
    /// subset, both quotes, attribute normalisation, line ends.
    @Test func theCornersMatchFoundation() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <!DOCTYPE r [ <!ENTITY x "y"> ]>
        <!-- a comment with <tags> in it -->
        <r xmlns:t="urn:t" a='single &amp; "double"' b="tab\there&#10;ref">
          <t:c v="&lt;&gt;&quot;&apos;&#x3042;&#12354;">text &amp; more &#65;&#x42;<![CDATA[<raw> & stuff]]>tail</t:c>
          <e/><e />
          <w xml:space="preserve">  spaces  </w>
          <lines>one\r\ntwo\rthree\nfour</lines>
        </r>
        """
        let data = Data(xml.utf8)
        let (_, a) = try Self.events(data, engine: .foundation)
        let (_, b) = try Self.events(data, engine: .scanner)
        #expect(a == b, "\(Self.firstDifference(a, b))")
        #expect(b.contains(.start("c", ["v": "<>\"'ああ"])))
        #expect(b.contains(.text("text & more AB<raw> & stufftail")))
        #expect(b.contains(.text("one\ntwo\nthree\nfour")))
        if case .start(_, let attrs)? = b.first(where: { if case .start("r", _) = $0 { return true }; return false }) {
            #expect(attrs["b"] == "tab here\nref", "a literal tab becomes a space, a character reference does not")
        }
    }

    /// A preserved subtree is the source bytes themselves — attributes in their own order, whitespace as it was.
    @Test func aCapturedSubtreeIsTheSourceBytes() throws {
        let xml = "<root><keep z=\"1\" a=\"2\">\n  <inner x='y'>t &amp; t</inner><empty/>\n</keep><other/></root>"
        let (_, events) = try Self.events(Data(xml.utf8), engine: .scanner, capture: ["keep", "other"])
        #expect(events.contains(.captured("keep", "<keep z=\"1\" a=\"2\">\n  <inner x='y'>t &amp; t</inner><empty/>\n</keep>")))
        #expect(events.contains(.captured("other", "<other/>")))
        #expect(!events.contains(.start("inner", ["x": "y"])), "events inside a capture are not delivered unless asked")
        let (_, delivered) = try Self.events(Data(xml.utf8), engine: .scanner, capture: ["keep"], delivering: true)
        #expect(delivered.contains(.start("inner", ["x": "y"])) && delivered.contains(.end("keep")))
    }

    /// Malformed markup is a thrown error, never a guess: mismatched, unclosed, unterminated, bad references.
    @Test(arguments: [
        "<a><b></a>", "<a>", "<a b='1'", "<a b=1/>", "<a>&#xFFFFFFFF;</a>", "<a></b>", "text only", "<a><!-- never closed</a>", "<a><![CDATA[open</a>"
    ])
    func malformedMarkupIsRefused(_ xml: String) {
        #expect(throws: SheetError.self) { try Self.events(Data(xml.utf8), engine: .scanner) }
    }

    /// What Foundation lets through, the scanner lets through too: an undefined entity is kept as written.
    @Test func anUndefinedEntityIsKeptAsWritten() throws {
        let (_, events) = try Self.events(Data("<a>x &nbsp; y</a>".utf8), engine: .scanner)
        #expect(events.contains(.text("x &nbsp; y")))
    }

    /// A part in UTF-16 goes to Foundation on its own; the automatic choice reads it all the same.
    @Test func aUTF16PartStillReads() throws {
        let text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><a b=\"1\">日本</a>"
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 { data.append(UInt8(unit & 0xff)); data.append(UInt8(unit >> 8)) }
        let (_, events) = try Self.events(data, engine: .automatic)
        #expect(events == [.start("a", ["b": "1"]), .text("日本"), .end("a")])
    }

    /// `fail` from a handler stops the scanner where it is, and the error is what comes out.
    @Test func aHandlerCanStopTheScanner() throws {
        final class Stopper: SAXHandler {
            var driver: SAXDriver?
            var rootAttributes: [String: String] = [:]
            var seen = 0
            func start(_ name: String, _ attrs: [String: String]) { seen += 1; if name == "stop" { fail(.invalidWorkbook("stopped")) } }
        }
        let h = Stopper()
        let d = SAXDriver(handler: h); h.driver = d
        #expect(throws: SheetError.invalidWorkbook("stopped")) { try d.run(Data("<a><stop/><never/><never/></a>".utf8), part: "p", engine: .scanner) }
        #expect(h.seen == 2)
    }
}
