import Foundation
import SheetCore

/// The print setup a Numbers sheet carries on its own archive (spec Appendix B.84): the page orientation, the
/// content scale, the margins, the first page number, and three header and three footer storages (left, centre,
/// right). Excel's header codes (`&L…&C…&R…`) are split the way the ODS writer splits them; `&P` becomes Numbers'
/// own page number (a switch on the sheet, drawn in the centre footer), and any other code has no place and is
/// named. What the sheet archive cannot hold — the paper size, fit-to-pages, the print area, title rows, page
/// breaks — stays reported by the writer.
enum NumbersPrint {
    static let defaultContentScale: Float = 0.72

    // MARK: - Header codes

    /// Splits `&L…&C…&R…` into its three zones. A leading run with no marker is the centre zone.
    static func split(_ code: String) -> (left: String?, center: String?, right: String?) {
        var left: String?, center: String?, right: String?
        var current: Character = "C"
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            switch current {
            case "L": left = (left ?? "") + buffer
            case "R": right = (right ?? "") + buffer
            default: center = (center ?? "") + buffer
            }
            buffer = ""
        }
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            if chars[i] == "&", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "L" || next == "C" || next == "R" { flush(); current = next; i += 2; continue }
                buffer.append(chars[i]); buffer.append(next); i += 2; continue
            }
            buffer.append(chars[i]); i += 1
        }
        flush()
        return (left, center, right)
    }

    /// The plain text of one zone: `&&` is an ampersand, `&P` is taken out (the caller turns the page number on),
    /// every other code (`&N`, `&D`, `&T`, `&F`, `&A`, `&Z`, a font `&"…"`, a size `&12`, `&B` …) is dropped and
    /// returned so the caller can name it.
    static func plainText(_ zone: String) -> (text: String, pageNumber: Bool, dropped: [String]) {
        var out = "", dropped: [String] = [], page = false
        let chars = Array(zone)
        var i = 0
        while i < chars.count {
            guard chars[i] == "&", i + 1 < chars.count else { out.append(chars[i]); i += 1; continue }
            let next = chars[i + 1]
            switch next {
            case "&": out.append("&"); i += 2
            case "P": page = true; i += 2
            case "\"":
                // a font name and style: &"Arial,Bold"
                var j = i + 2
                while j < chars.count, chars[j] != "\"" { j += 1 }
                dropped.append(String(chars[i...min(j, chars.count - 1)]))
                i = j + 1
            case let d where d.isNumber:
                var j = i + 1
                while j < chars.count, chars[j].isNumber { j += 1 }
                dropped.append(String(chars[i..<j]))
                i = j
            default:
                dropped.append("&" + String(next)); i += 2
            }
        }
        return (out, page, dropped)
    }

    /// The inverse: three zone texts back into one Excel code, the page number in the centre when it is shown.
    static func code(left: String?, center: String?, right: String?) -> String? {
        var s = ""
        if let left, !left.isEmpty { s += "&L" + left.replacingOccurrences(of: "&", with: "&&") }
        if let center, !center.isEmpty { s += "&C" + center }
        if let right, !right.isEmpty { s += "&R" + right.replacingOccurrences(of: "&", with: "&&") }
        return s.isEmpty ? nil : s
    }

    // MARK: - Writing

    /// What the sheet archive says about printing, applied from the model. Returns the warnings the mapping raised.
    static func apply(_ sheet: Sheet, to sid: Int, in doc: NumbersDocument) -> [ConversionWarning] {
        var warnings: [ConversionWarning] = []
        func warn(_ kind: ConversionWarning.Kind, _ message: String) {
            warnings.append(ConversionWarning(kind, subject: .formatting, sheet: sheet.name, message: message))
        }
        let setup = sheet.pageSetup
        var showPageNumbers: Bool?
        var dropped: [String] = []
        // headers and footers: the odd ones, zone by zone, into the storages the template already has
        for (code, refs, isFooter) in [(sheet.headerFooter.oddHeader, doc.object(sid)?.references("headers") ?? [], false),
                                       (sheet.headerFooter.oddFooter, doc.object(sid)?.references("footers") ?? [], true)] {
            guard let code, !code.isEmpty else { continue }
            guard refs.count == 3 else { warn(.dropped, "the \(isFooter ? "footer" : "header") is dropped: the template's sheet has no header / footer storages"); continue }
            let zones = split(code)
            for (zone, ref) in zip([zones.left, zones.center, zones.right], refs) {
                let plain = plainText(zone ?? "")
                dropped += plain.dropped
                if plain.pageNumber { showPageNumbers = true }
                doc.update(ref) { storage in
                    if !plain.text.isEmpty { storage.set("text", string: plain.text) } else { storage.remove("text") }
                    storage.remove("table_attachment")   // the template's centre footer holds Numbers' own page number
                }
            }
            if showPageNumbers == nil { showPageNumbers = false }
        }
        if !dropped.isEmpty {
            warn(.degraded, "header / footer code(s) \(Set(dropped).sorted().joined(separator: " ")) dropped: Numbers' headers hold plain text and a page number")
        }
        if sheet.headerFooter.oddHeader.map({ split($0) }).flatMap({ [$0.left, $0.center, $0.right].compactMap { $0 }.contains { plainText($0).pageNumber } }) == true
            || sheet.headerFooter.oddFooter.map({ split($0) }).flatMap({ [$0.left, $0.right].compactMap { $0 }.contains { plainText($0).pageNumber } }) == true {
            warn(.degraded, "the page number (&P) is drawn where Numbers draws it, in the centre of the footer")
        }
        if sheet.headerFooter.differentOddEven && (sheet.headerFooter.evenHeader != nil || sheet.headerFooter.evenFooter != nil)
            || sheet.headerFooter.differentFirst && (sheet.headerFooter.firstHeader != nil || sheet.headerFooter.firstFooter != nil) {
            warn(.dropped, "the even-page / first-page header and footer are dropped: Numbers has one header and one footer per sheet")
        }
        doc.update(sid) { archive in
            if let showPageNumbers { archive.set("show_page_numbers", bool: showPageNumbers) }
            switch setup.orientation {
            case .landscape?: archive.set("in_portrait_page_orientation", bool: false)
            case .portrait?: archive.set("in_portrait_page_orientation", bool: true)
            default: break
            }
            if let scale = setup.scale, scale > 0 { archive.set("content_scale", float: Float(scale) / 100) }
            if setup.fitToWidth != nil || setup.fitToHeight != nil { archive.set("is_autofit_on", bool: true) }
            if let first = setup.firstPageNumber {
                archive.set("start_page_number", int: first)
                archive.set("using_start_page_number", bool: setup.usesFirstPageNumber ?? true)
            }
            let m = sheet.pageMargins
            if m != PageMargins() {
                var insets = ProtoMessage(typeName: "TSD.EdgeInsetsArchive")
                insets.set("top", float: Float(m.top * 72)); insets.set("left", float: Float(m.left * 72))
                insets.set("bottom", float: Float(m.bottom * 72)); insets.set("right", float: Float(m.right * 72))
                archive.set("print_margins", message: insets)
                archive.set("page_header_inset", float: Float(m.header * 72))
                archive.set("page_footer_inset", float: Float(m.footer * 72))
            }
        }
        if setup.fitToWidth != nil || setup.fitToHeight != nil {
            warn(.degraded, "fit-to-pages is written as Numbers' auto-fit (one page wide): Numbers has no page count to fit to")
        }
        var stillDropped: [String] = []
        if let code = setup.paperSize, NumbersPrint.paperNames[code] == nil { stillDropped.append("paper size \(code)") }
        if !sheet.printArea.isEmpty { stillDropped.append("print area") }
        // title rows / columns that start at the first row / column are the first table's header rows / columns,
        // repeated on every page (B.86); any other range has no place
        if let rows = sheet.printTitleRows, rows.lowerBound != 1 { stillDropped.append("title rows \(rows.lowerBound)-\(rows.upperBound)") }
        if let cols = sheet.printTitleColumns, cols.lowerBound != 1 { stillDropped.append("title columns \(cols.lowerBound)-\(cols.upperBound)") }
        if !sheet.rowBreaks.isEmpty || !sheet.columnBreaks.isEmpty { stillDropped.append("page breaks") }
        if !stillDropped.isEmpty {
            warn(.dropped, "the \(stillDropped.joined(separator: ", ")) \(stillDropped.count == 1 ? "is" : "are") dropped: Numbers prints a canvas, not a page grid")
        }
        return warnings
    }

    // MARK: - The paper (document-level) and the title rows (B.86)

    /// Excel paper-size codes → the name Numbers keeps in `TN.DocumentArchive.paper_id`.
    static let paperNames: [Int: String] = [1: "na-letter", 5: "na-legal", 8: "iso-a3", 9: "iso-a4", 11: "iso-a5", 12: "jis-b4", 13: "jis-b5"]

    /// The paper of the document: Numbers keeps one for the whole document, so the first sheet that names one
    /// decides, and a sheet asking for another is said so.
    static func applyPaper(_ sheets: [Sheet], to doc: NumbersDocument) -> [ConversionWarning] {
        var warnings: [ConversionWarning] = []
        var chosen: (code: Int, sheet: String)?
        for sheet in sheets {
            guard let code = sheet.pageSetup.paperSize, let name = paperNames[code], let cm = PageSetup.paperSizesInCentimetres[code] else { continue }
            if let chosen {
                if chosen.code != code {
                    warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheet.name,
                                                      message: "the paper size \(code) is written as \(chosen.code): Numbers has one paper for the document, and the sheet \(chosen.sheet) named it first"))
                }
                continue
            }
            chosen = (code, sheet.name)
            doc.update(NumbersDocument.documentID) { d in
                d.set("paper_id", string: name)
                var size = ProtoMessage(typeName: "TSP.Size")
                size.set("width", float: Float((cm.width / 2.54 * 72).rounded())); size.set("height", float: Float((cm.height / 2.54 * 72).rounded()))
                d.set("page_size", message: size)
            }
        }
        return warnings
    }

    /// The document's paper, read back as the Excel code whose size it is (nil for a paper the table lacks).
    static func paperCode(of doc: any NumbersObjectStore) -> Int? {
        guard let document = doc.object(NumbersDocument.documentID) else { return nil }
        if let name = document.string("paper_id"), let code = paperNames.first(where: { $0.value == name })?.key { return code }
        guard let size = document.message("page_size"), let w = size.float("width"), let h = size.float("height") else { return nil }
        return PageSetup.paperSizesInCentimetres.first { abs(Float($0.value.width / 2.54 * 72) - w) < 2 && abs(Float($0.value.height / 2.54 * 72) - h) < 2 }?.key
    }

    /// Title rows / columns starting at the first row / column → the table's header rows / columns, repeated on
    /// every printed page. Returns the header counts to set (nil = leave the table's own), and the warnings.
    static func repeatingHeaders(_ sheet: Sheet) -> (rows: Int?, columns: Int?, warnings: [ConversionWarning]) {
        var warnings: [ConversionWarning] = []
        var rows: Int?, columns: Int?
        if let r = sheet.printTitleRows, r.lowerBound == 1 {
            rows = r.count
            if let fp = sheet.freezePanes, fp.row - 1 != r.count {
                warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheet.name,
                                                  message: "the title rows (\(r.count)) and the frozen rows (\(fp.row - 1)) differ: Numbers has one header-row count, and the title rows win"))
            }
        }
        if let c = sheet.printTitleColumns, c.lowerBound == 1 {
            columns = c.count
            if let fp = sheet.freezePanes, fp.column - 1 != c.count {
                warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheet.name,
                                                  message: "the title columns (\(c.count)) and the frozen columns (\(fp.column - 1)) differ: Numbers has one header-column count, and the title columns win"))
            }
        }
        return (rows, columns, warnings)
    }

    // MARK: - Reading

    /// The sheet archive's print setup, into the model.
    static func read(_ archive: ProtoMessage, into sheet: inout Sheet, doc: any NumbersObjectStore) {
        if archive.bool("in_portrait_page_orientation") == false { sheet.pageSetup.orientation = .landscape }
        if let scale = archive.float("content_scale"), scale > 0 { sheet.pageSetup.scale = Int((scale * 100).rounded()) }
        if archive.bool("using_start_page_number") == true, let first = archive.int("start_page_number") {
            sheet.pageSetup.firstPageNumber = first
            sheet.pageSetup.usesFirstPageNumber = true
        }
        if let insets = archive.message("print_margins") {
            var m = PageMargins()
            m.top = Double(insets.float("top") ?? 72) / 72; m.left = Double(insets.float("left") ?? 54) / 72
            m.bottom = Double(insets.float("bottom") ?? 72) / 72; m.right = Double(insets.float("right") ?? 54) / 72
            if let h = archive.float("page_header_inset") { m.header = Double(h) / 72 }
            if let f = archive.float("page_footer_inset") { m.footer = Double(f) / 72 }
            sheet.pageMargins = m
        }
        if let code = paperCode(of: doc) { sheet.pageSetup.paperSize = code }
        let showsPageNumbers = archive.bool("show_page_numbers") ?? true
        func zones(_ refs: [Int], pageNumberInCentre: Bool) -> String? {
            guard refs.count == 3 else { return nil }
            let texts = refs.map { ref -> String in
                let text = doc.object(ref)?.string("text") ?? ""
                return text.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
            var centre = texts[1]
            if pageNumberInCentre { centre = centre.replacingOccurrences(of: "&", with: "&&") + "&P" } else { centre = centre.replacingOccurrences(of: "&", with: "&&") }
            return code(left: texts[0], center: centre, right: texts[2])
        }
        sheet.headerFooter.oddHeader = zones(archive.references("headers"), pageNumberInCentre: false)
        sheet.headerFooter.oddFooter = zones(archive.references("footers"), pageNumberInCentre: showsPageNumbers)
    }
}
