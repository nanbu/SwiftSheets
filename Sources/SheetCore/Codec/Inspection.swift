import Foundation

/// What a file says about itself before any cell of it is read (spec Appendix B.39.3): the sheets it declares and
/// how many cells each says it holds, what the package expands to, and who wrote it. Enough for a caller to decide
/// whether to read it at all, which sheets, and with what `ReadOptions.cellLimit`.
public struct WorkbookSummary: Sendable, Hashable {
    public var format: SheetFormat
    public var sheets: [SheetSummary]
    /// The generating application, when the file names it.
    public var producer: SourceInfo?
    /// What every part of the package expands to, added up (the file's own size for CSV). The working size of a
    /// workbook is larger — reckon on 100–200 bytes per cell — but this is what the reader will pass through.
    public var expandedBytes: Int
    /// Parts in the package (1 for CSV).
    public var partCount: Int

    public init(format: SheetFormat, sheets: [SheetSummary], producer: SourceInfo? = nil, expandedBytes: Int, partCount: Int) {
        self.format = format; self.sheets = sheets; self.producer = producer; self.expandedBytes = expandedBytes; self.partCount = partCount
    }

    /// Cells declared over every sheet, when every sheet declares them; nil when any sheet cannot say.
    public var declaredCellCount: Int? {
        var total = 0
        for s in sheets { guard let n = s.declaredCellCount else { return nil }; total += n }
        return total
    }
}

/// One sheet as the file declares it.
public struct SheetSummary: Sendable, Hashable {
    public var name: String
    /// False for a chart sheet, a dialog sheet, a Numbers form — a tab that is not a grid of cells.
    public var isGrid = true
    /// The used range the file declares (XLSX `<dimension>`, a Numbers table's rows × columns). Nil when the file
    /// does not say (ODS, CSV) or the sheet holds several tables.
    public var declaredRange: CellRange?
    /// Cells the file declares: the area of `declaredRange` for XLSX and Numbers (the declaration can be wrong
    /// — some writers put "A1" whatever the sheet holds), the cells that carry a value for ODS (counted from the
    /// run-length markup without expanding it). Nil when the file does not say.
    public var declaredCellCount: Int?
    /// Cells actually present, counted by walking the sheet's markup (`InspectOptions.countCells`). Every `<c>`
    /// element for XLSX, which is what a read will hold. Nil unless counted.
    public var countedCellCount: Int?
    /// Rows the sheet holds, where a count is cheap: rows that carry something for ODS, lines for CSV, `<row>`
    /// elements for XLSX when `countCells` is on.
    public var rowCount: Int?
    /// Tables on the sheet: one for a grid, several only for Numbers.
    public var tableCount = 1
    /// What the sheet's own part expands to, when the sheet has one (XLSX). Nil for a format where the sheets
    /// share a part (ODS) or are spread over many (Numbers).
    public var partBytes: Int?

    public init(name: String) { self.name = name }
}

/// How much work `Workbook.inspect` may do.
public struct InspectOptions: Sendable, Hashable {
    /// Walk each sheet's markup and count the cells that are really there, rather than taking the declaration.
    /// Costs a pass over every sheet part (no model is built); off by default.
    public var countCells = false
    /// The original file name, when known — the extension hint for plain text (`.tsv`).
    public var filename: String?
    /// What the container may declare about itself (`ReadOptions.limits`).
    public var limits = ZipLimits()

    public init(countCells: Bool = false, filename: String? = nil, limits: ZipLimits = ZipLimits()) {
        self.countCells = countCells; self.filename = filename; self.limits = limits
    }
}

/// A start or end tag as the byte scanner found it: its bytes from `<` to `>`, and a few questions answered
/// without building anything.
package struct ScannedTag {
    package let bytes: ArraySlice<UInt8>
    package let isEnd: Bool
    /// The element's local name — "table" for `<table:table …>`.
    package let localName: String

    /// An attribute's value, entities decoded; nil when absent. `name` is matched as written (with its prefix).
    package func attribute(_ name: String) -> String? {
        let pattern = Array((" " + name + "=").utf8)
        guard let i = ScannedTag.find(pattern, in: bytes) else { return nil }
        var j = i + pattern.count
        guard j < bytes.endIndex else { return nil }
        let quote = bytes[j]
        guard quote == 0x22 || quote == 0x27 else { return nil }
        j += 1
        let start = j
        while j < bytes.endIndex, bytes[j] != quote { j += 1 }
        guard j < bytes.endIndex else { return nil }
        let raw = bytes[start..<j]
        var text = String(decoding: raw, as: UTF8.self)
        if text.contains("&") { text = ScannedTag.decodeEntities(text) }
        return text
    }

    package func hasAttribute(_ name: String) -> Bool {
        ScannedTag.find(Array((" " + name + "=").utf8), in: bytes) != nil
    }

    static func find(_ pattern: [UInt8], in bytes: ArraySlice<UInt8>) -> Int? {
        guard pattern.count <= bytes.count else { return nil }
        let last = bytes.endIndex - pattern.count
        var i = bytes.startIndex
        let first = pattern[0]
        while i <= last {
            if bytes[i] == first {
                var k = 1
                while k < pattern.count, bytes[i + k] == pattern[k] { k += 1 }
                if k == pattern.count { return i }
            }
            i += 1
        }
        return nil
    }

    package static func decodeEntities(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[amp...]
            guard let semi = after.firstIndex(of: ";") else { out += after; return out }
            let entity = after[after.index(after: amp)..<semi]
            switch entity {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                if entity.hasPrefix("#x"), let v = UInt32(entity.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                else if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                else { out += after[amp...semi] }
            }
            rest = after[after.index(after: semi)...]
        }
        return out + rest
    }
}

/// Walks XML as bytes, a piece at a time, and reports the tags asked for — without a parser, without decoding
/// text, without holding more than the piece in hand. For the questions `Workbook.inspect` asks (which sheets,
/// how many cells) that is all the markup has to yield.
package enum TagScanner {
    /// `next` yields the pieces (nil at the end). `names` are local names (without prefix); `body` receives each
    /// matching start or end tag and returns false to stop early.
    package static func scan(_ next: () throws -> Data?, names: Set<String>, _ body: (ScannedTag) throws -> Bool) throws {
        var carry: [UInt8] = []
        var stopped = false
        while !stopped, let piece = try next() {
            carry.append(contentsOf: piece)
            var consumed = 0
            try carry.withUnsafeBufferPointer { b in
                var i = 0
                let n = b.count
                scanning: while i < n {
                    guard b[i] == 0x3C else { i += 1; continue }
                    // a tag starts here; it must end in this buffer, else it waits for the next piece
                    var j = i + 1
                    guard j < n else { break }
                    let kind = b[j]
                    if kind == 0x3F || kind == 0x21 {           // <? … ?>  <!-- … -->  <![CDATA[ … ]]>
                        if kind == 0x21, j + 7 < n, b[j + 1] == 0x5B, b[j + 2] == 0x43 {   // <![CDATA[
                            var k = j + 8
                            while k + 2 < n, !(b[k] == 0x5D && b[k + 1] == 0x5D && b[k + 2] == 0x3E) { k += 1 }
                            guard k + 2 < n else { break }
                            i = k + 3; consumed = i; continue
                        }
                        while j < n, b[j] != 0x3E { j += 1 }
                        guard j < n else { break }
                        i = j + 1; consumed = i; continue
                    }
                    let isEnd = kind == 0x2F
                    if isEnd { j += 1 }
                    let nameStart = j
                    while j < n, b[j] != 0x20, b[j] != 0x3E, b[j] != 0x2F, b[j] != 0x09, b[j] != 0x0A, b[j] != 0x0D { j += 1 }
                    guard j < n else { break }
                    let nameEnd = j
                    // find the closing '>' (attribute values may hold '>' — walk quotes)
                    var quote: UInt8 = 0
                    while j < n {
                        let c = b[j]
                        if quote != 0 { if c == quote { quote = 0 } }
                        else if c == 0x22 || c == 0x27 { quote = c }
                        else if c == 0x3E { break }
                        j += 1
                    }
                    guard j < n else { break }
                    // local name: after the last ':' in the name
                    var local = nameStart
                    var k = nameStart
                    while k < nameEnd { if b[k] == 0x3A { local = k + 1 }; k += 1 }
                    let localName = String(decoding: UnsafeBufferPointer(rebasing: b[local..<nameEnd]), as: UTF8.self)
                    if names.contains(localName) {
                        let tag = ScannedTag(bytes: carry[i...j], isEnd: isEnd, localName: localName)
                        if try !body(tag) { stopped = true; consumed = j + 1; break scanning }
                    }
                    i = j + 1
                    consumed = i
                }
                if !stopped { consumed = Swift.max(consumed, 0) }
            }
            if stopped { break }
            // keep the unfinished tail for the next piece; a tail that never closes is not markup worth keeping
            if consumed > 0 { carry.removeFirst(consumed) }
            if carry.count > 4 << 20 { carry.removeAll() }
        }
    }

    /// The same over a whole buffer.
    package static func scan(_ data: Data, names: Set<String>, _ body: (ScannedTag) throws -> Bool) throws {
        var given = false
        try scan({ if given { return nil }; given = true; return data }, names: names, body)
    }
}
