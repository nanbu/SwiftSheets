import Foundation

/// A tokenizer for the XML inside spreadsheet packages, written for the shape of that XML: UTF-8, no external
/// entities, a handful of element names repeated a million times (spec Appendix B.39.6).
///
/// It walks the bytes where they lie and hands the handler the same three events Foundation's parser did —
/// start, text, end — but without the costs that parser carried for every element: a bridged `NSString` per
/// name and per attribute value, a dictionary built on the other side of an Objective-C boundary, and a
/// `String` made of every run of characters even when the handler wanted none of them. Names are compared as
/// bytes, strings are made straight from UTF-8, and a preserved subtree is the source bytes themselves.
///
/// What it accepts is well-formed XML 1.0 as spreadsheet writers produce it: the declaration, comments,
/// processing instructions, a DOCTYPE (skipped, internal subset included — its entities are not expanded),
/// CDATA, the five predefined entities and character references, both attribute quotes. Attribute values are
/// normalised as the specification says (a literal tab or newline becomes a space; a character reference does
/// not), and line ends in text are normalised to `\n`. A mismatched or unclosed element, a bad character
/// reference or a tag that never closes is `malformedPart`. Undefined entities are kept literally — a
/// spreadsheet has no DTD to define them, and a reader that stops on `&nbsp;` in a comment helps nobody.
package struct XMLScanner {
    private let handler: SAXHandler
    private let part: String
    private let driver: SAXDriver

    package init(handler: SAXHandler, driver: SAXDriver, part: String) {
        self.handler = handler; self.driver = driver; self.part = part
    }

    private func malformed(_ detail: String, at offset: Int) -> SheetError {
        .malformedPart(path: part, detail: "\(detail) at byte \(offset)")
    }

    /// Parses `data` to the end, or until the driver is told to stop (`fail` / capture finished early).
    package func run(_ data: Data) throws {
        try data.withUnsafeBytes { raw in try run(raw.bindMemory(to: UInt8.self)) }
    }

    package func run(_ b: UnsafeBufferPointer<UInt8>) throws {
        let n = b.count
        var i = 0
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        var stack: [Range<Int>] = []          // qualified names of open elements, as byte ranges in `b`
        var textStart = -1                    // start of the pending run of character data
        var textHasSpecial = false            // the run holds an entity or a carriage return
        var sawRoot = false
        var attrs: [String: String] = [:]

        @inline(__always) func name(_ r: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: b[r]), as: UTF8.self) }
        @inline(__always) func isNameEnd(_ c: UInt8) -> Bool { c == 0x20 || c == 0x3E || c == 0x2F || c == 0x09 || c == 0x0A || c == 0x0D }
        @inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        func flushText(upTo end: Int) throws {
            guard textStart >= 0 else { return }
            let start = textStart
            textStart = -1
            guard end > start else { return }
            if textHasSpecial {
                let s = try decode(b, start..<end, attribute: false)
                textHasSpecial = false
                driver.scannerText(s)
            } else {
                driver.scannerText(name(start..<end))
            }
        }

        while i < n {
            let c = b[i]
            if c != 0x3C {                                           // character data
                if stack.isEmpty { i += 1; continue }                // outside the root there is only whitespace to skip
                if textStart < 0 { textStart = i }
                if c == 0x26 || c == 0x0D { textHasSpecial = true }
                i += 1
                continue
            }
            // a tag of some kind starts here
            try flushText(upTo: i)
            let tagStart = i
            guard i + 1 < n else { throw malformed("unterminated tag", at: i) }
            let kind = b[i + 1]
            if kind == 0x3F {                                        // <? … ?>
                i += 2
                while i + 1 < n, !(b[i] == 0x3F && b[i + 1] == 0x3E) { i += 1 }
                guard i + 1 < n else { throw malformed("unterminated processing instruction", at: tagStart) }
                i += 2
                continue
            }
            if kind == 0x21 {                                        // <!-- --> <![CDATA[ ]]> <!DOCTYPE …>
                if i + 3 < n, b[i + 2] == 0x2D, b[i + 3] == 0x2D {
                    i += 4
                    while i + 2 < n, !(b[i] == 0x2D && b[i + 1] == 0x2D && b[i + 2] == 0x3E) { i += 1 }
                    guard i + 2 < n else { throw malformed("unterminated comment", at: tagStart) }
                    i += 3
                    continue
                }
                if i + 8 < n, b[i + 2] == 0x5B, b[i + 3] == 0x43, b[i + 4] == 0x44, b[i + 5] == 0x41, b[i + 6] == 0x54, b[i + 7] == 0x41, b[i + 8] == 0x5B {
                    i += 9
                    let start = i
                    while i + 2 < n, !(b[i] == 0x5D && b[i + 1] == 0x5D && b[i + 2] == 0x3E) { i += 1 }
                    guard i + 2 < n else { throw malformed("unterminated CDATA section", at: tagStart) }
                    driver.scannerText(name(start..<i))
                    i += 3
                    continue
                }
                // DOCTYPE or another declaration: skip it, internal subset included
                i += 2
                var depth = 0
                var quote: UInt8 = 0
                while i < n {
                    let d = b[i]
                    if quote != 0 { if d == quote { quote = 0 } }
                    else if d == 0x22 || d == 0x27 { quote = d }
                    else if d == 0x5B { depth += 1 }
                    else if d == 0x5D { depth -= 1 }
                    else if d == 0x3E, depth <= 0 { break }
                    i += 1
                }
                guard i < n else { throw malformed("unterminated declaration", at: tagStart) }
                i += 1
                continue
            }
            if kind == 0x2F {                                        // </name>
                i += 2
                let nameStart = i
                while i < n, !isNameEnd(b[i]) { i += 1 }
                let nameEnd = i
                while i < n, isSpace(b[i]) { i += 1 }
                guard i < n, b[i] == 0x3E else { throw malformed("malformed end tag", at: tagStart) }
                i += 1
                guard let open = stack.popLast(), open.count == nameEnd - nameStart,
                      memcmp(b.baseAddress! + open.lowerBound, b.baseAddress! + nameStart, open.count) == 0 else {
                    throw malformed("end tag </\(name(nameStart..<nameEnd))> does not match the open element", at: tagStart)
                }
                try driver.scannerEnd(qualified: name(open), tagEnd: i)
                if driver.stopped { return }
                continue
            }
            // <name attr="…" … > or <name … />
            i += 1
            let nameStart = i
            while i < n, !isNameEnd(b[i]) { i += 1 }
            let nameEnd = i
            guard nameEnd > nameStart else { throw malformed("tag without a name", at: tagStart) }
            attrs.removeAll(keepingCapacity: true)
            var selfClosing = false
            while true {
                while i < n, isSpace(b[i]) { i += 1 }
                guard i < n else { throw malformed("unterminated start tag", at: tagStart) }
                if b[i] == 0x3E { i += 1; break }
                if b[i] == 0x2F {
                    guard i + 1 < n, b[i + 1] == 0x3E else { throw malformed("malformed start tag", at: tagStart) }
                    i += 2; selfClosing = true; break
                }
                let aStart = i
                while i < n, b[i] != 0x3D, !isSpace(b[i]), b[i] != 0x3E, b[i] != 0x2F { i += 1 }
                let aEnd = i
                while i < n, isSpace(b[i]) { i += 1 }
                guard i < n, b[i] == 0x3D, aEnd > aStart else { throw malformed("attribute without a value", at: aStart) }
                i += 1
                while i < n, isSpace(b[i]) { i += 1 }
                guard i < n, b[i] == 0x22 || b[i] == 0x27 else { throw malformed("attribute value without quotes", at: aStart) }
                let quote = b[i]
                i += 1
                let vStart = i
                var special = false
                while i < n, b[i] != quote { if b[i] == 0x26 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { special = true }; i += 1 }
                guard i < n else { throw malformed("unterminated attribute value", at: aStart) }
                let value = special ? try decode(b, vStart..<i, attribute: true) : name(vStart..<i)
                attrs[name(aStart..<aEnd)] = value
                i += 1
            }
            let qualified = name(nameStart..<nameEnd)
            if !sawRoot { sawRoot = true; handler.rootAttributes = attrs }
            try driver.scannerStart(qualified: qualified, attributes: attrs, tagStart: tagStart, tagEnd: i)
            if driver.stopped { return }
            if selfClosing {
                try driver.scannerEnd(qualified: qualified, tagEnd: i)
                if driver.stopped { return }
            } else {
                stack.append(nameStart..<nameEnd)
            }
        }
        try flushText(upTo: n)
        guard sawRoot else { throw malformed("no root element", at: 0) }
        guard stack.isEmpty else { throw malformed("element <\(name(stack.last!))> is never closed", at: n) }
    }

    /// Text with entities decoded and line ends normalised; attribute values also have literal whitespace
    /// characters turned to spaces (XML 1.0 §3.3.3).
    private func decode(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>, attribute: Bool) throws -> String {
        var out = [UInt8]()
        out.reserveCapacity(r.count)
        var i = r.lowerBound
        while i < r.upperBound {
            let c = b[i]
            switch c {
            case 0x26:                                               // &
                var j = i + 1
                while j < r.upperBound, b[j] != 0x3B, j - i < 12 { j += 1 }
                guard j < r.upperBound, b[j] == 0x3B else { out.append(c); i += 1; continue }   // a lone '&': kept
                let body = UnsafeBufferPointer(rebasing: b[(i + 1)..<j])
                if let scalar = XMLScanner.entity(body) {
                    var s = scalar
                    if attribute, s == 0x0A || s == 0x09 || s == 0x0D { s = scalar }   // references survive normalisation
                    guard let u = Unicode.Scalar(s) else { throw malformed("character reference out of range", at: i) }
                    out.append(contentsOf: Array(String(u).utf8))
                    i = j + 1
                } else {
                    out.append(contentsOf: b[i...j])                 // undefined entity: kept as written
                    i = j + 1
                }
            case 0x0D:
                if i + 1 < r.upperBound, b[i + 1] == 0x0A { i += 1 }  // \r\n → \n
                out.append(attribute ? 0x20 : 0x0A)
                i += 1
            case 0x0A where attribute, 0x09 where attribute:
                out.append(0x20); i += 1
            default:
                out.append(c); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The scalar an entity body names: `amp`, `lt`, `gt`, `quot`, `apos`, `#123`, `#x7B`. Nil for anything else.
    static func entity(_ body: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard !body.isEmpty else { return nil }
        if body[0] == 0x23 {                                         // #
            var v: UInt32 = 0
            if body.count > 1, body[1] == 0x78 {                     // x
                guard body.count > 2 else { return nil }
                for k in 2..<body.count {
                    let d = body[k]
                    let digit: UInt32
                    switch d {
                    case 0x30...0x39: digit = UInt32(d - 0x30)
                    case 0x41...0x46: digit = UInt32(d - 0x41 + 10)
                    case 0x61...0x66: digit = UInt32(d - 0x61 + 10)
                    default: return nil
                    }
                    v = v &* 16 &+ digit
                    if v > 0x10FFFF { return 0xFFFF_FFFF }
                }
            } else {
                guard body.count > 1 else { return nil }
                for k in 1..<body.count {
                    let d = body[k]
                    guard d >= 0x30, d <= 0x39 else { return nil }
                    v = v &* 10 &+ UInt32(d - 0x30)
                    if v > 0x10FFFF { return 0xFFFF_FFFF }
                }
            }
            return v
        }
        switch body.count {
        case 2 where body[0] == 0x6C && body[1] == 0x74: return 0x3C                                   // lt
        case 2 where body[0] == 0x67 && body[1] == 0x74: return 0x3E                                   // gt
        case 3 where body[0] == 0x61 && body[1] == 0x6D && body[2] == 0x70: return 0x26                // amp
        case 4 where body[0] == 0x71 && body[1] == 0x75 && body[2] == 0x6F && body[3] == 0x74: return 0x22   // quot
        case 4 where body[0] == 0x61 && body[1] == 0x70 && body[2] == 0x6F && body[3] == 0x73: return 0x27   // apos
        default: return nil
        }
    }
}
