import Foundation
import SheetCore

/// Print setup in ODF: one `style:page-layout` and one `style:master-page` per sheet, both in styles.xml, named
/// from the sheet's own table style (`style:master-page-name`).
///
/// Excel keeps all of this on the worksheet (`<pageSetup>`, `<pageMargins>`, `<headerFooter>`, `<printOptions>`);
/// ODF splits it between the layout (geometry, what to print) and the master page (the header and footer text).
/// The names are plain (`pm1`, `PageStyle1`) because ODF encodes an underscore in a style name as `_5f_` and the
/// attributes that reference a style disagree about which spelling they use.
enum ODSPageStyles {
    struct Page: Equatable {
        var margins = PageMargins()
        var setup = PageSetup()
        var options = PrintOptions()
        var printGridLines = false
        var headerFooter = HeaderFooter()

        init(_ sheet: Sheet) {
            margins = sheet.pageMargins
            setup = sheet.pageSetup
            options = sheet.printOptions
            printGridLines = sheet.printOptions.gridLines
            headerFooter = sheet.headerFooter
        }
        /// True when the sheet asks for nothing beyond the defaults, so it can share the document's plain page.
        var isDefault: Bool {
            margins == PageMargins() && setup == PageSetup() && options == PrintOptions() && headerFooter.isEmpty
        }
    }

    /// Excel paper sizes SwiftSheets can give ODF a page size for, in centimetres (portrait).
    static let paperSizes: [Int: (Double, Double)] = [
        1: (21.59, 27.94),    // Letter
        5: (21.59, 35.56),    // Legal
        8: (29.7, 42.0),      // A3
        9: (21.0, 29.7),      // A4
        11: (14.8, 21.0),     // A5
        12: (25.0, 35.3),     // B4 (JIS)
        13: (17.6, 25.0),     // B5 (JIS)
    ]

    static func cm(inches: Double) -> String { ODSLength.cmValue(inches * 2.54) }

    /// `<style:page-layout>` for one sheet.
    static func layoutXML(name: String, _ p: Page) -> String {
        var props = ""
        if let size = p.setup.paperSize.flatMap({ paperSizes[$0] }) {
            let landscape = p.setup.orientation == .landscape
            let w = landscape ? size.1 : size.0, h = landscape ? size.0 : size.1
            props += " fo:page-width=\"\(ODSLength.cmValue(w))\" fo:page-height=\"\(ODSLength.cmValue(h))\""
        }
        props += " style:num-format=\"1\""
        if let o = p.setup.orientation, o != .default { props += " style:print-orientation=\"\(o.rawValue)\"" }
        // ODF's page margin stops where the header begins, and the header's own height fills the rest of what
        // Excel calls the top margin: `fo:margin-top` is Excel's *header* margin, and the header's `fo:min-height`
        // is the difference. LibreOffice reads it back exactly that way.
        props += " fo:margin-top=\"\(cm(inches: Swift.min(p.margins.header, p.margins.top)))\""
        props += " fo:margin-bottom=\"\(cm(inches: Swift.min(p.margins.footer, p.margins.bottom)))\""
        props += " fo:margin-left=\"\(cm(inches: p.margins.left))\" fo:margin-right=\"\(cm(inches: p.margins.right))\""
        props += " style:print-page-order=\"ttb\""
        if p.setup.useFirstPageNumber == true, let n = p.setup.firstPageNumber { props += " style:first-page-number=\"\(n)\"" }
        if let scale = p.setup.scale { props += " style:scale-to=\"\(scale)%\"" }
        else if p.setup.fitToWidth != nil || p.setup.fitToHeight != nil {
            props += " style:scale-to-X=\"\(p.setup.fitToWidth ?? 1)\" style:scale-to-Y=\"\(p.setup.fitToHeight ?? 1)\""
        }
        switch (p.options.horizontalCentered, p.options.verticalCentered) {
        case (true, true): props += " style:table-centering=\"both\""
        case (true, false): props += " style:table-centering=\"horizontal\""
        case (false, true): props += " style:table-centering=\"vertical\""
        case (false, false): break
        }
        var print = ["charts", "drawings", "objects", "zero-values"]
        if p.printGridLines { print.append("grid") }
        if p.options.headings { print.append("headers") }
        props += " style:writing-mode=\"lr-tb\" style:print=\"\(print.sorted().joined(separator: " "))\""

        var s = "<style:page-layout style:name=\"\(name)\"><style:page-layout-properties\(props)/>"
        let headerHeight = Swift.max(0, p.margins.top - Swift.min(p.margins.header, p.margins.top))
        let footerHeight = Swift.max(0, p.margins.bottom - Swift.min(p.margins.footer, p.margins.bottom))
        s += "<style:header-style><style:header-footer-properties fo:min-height=\"\(cm(inches: headerHeight))\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:margin-bottom=\"0cm\"/></style:header-style>"
        s += "<style:footer-style><style:header-footer-properties fo:min-height=\"\(cm(inches: footerHeight))\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:margin-top=\"0cm\"/></style:footer-style>"
        return s + "</style:page-layout>"
    }

    /// Reads a master page and its layout back onto a sheet.
    static func apply(master: ODSMasterPage, layout: ODSPageLayout?, to sheet: inout Sheet) {
        if let l = layout {
            let p = l.properties
            if let o = ODSAttr.get(p, "style:print-orientation") { sheet.pageSetup.orientation = PageSetup.Orientation(rawValue: o) }
            if let n = ODSAttr.int(p, "style:first-page-number") { sheet.pageSetup.firstPageNumber = n; sheet.pageSetup.useFirstPageNumber = true }
            if let scale = ODSAttr.get(p, "style:scale-to"), let v = Int(scale.replacingOccurrences(of: "%", with: "")) { sheet.pageSetup.scale = v }
            if let x = ODSAttr.int(p, "style:scale-to-X") { sheet.pageSetup.fitToWidth = x }
            if let y = ODSAttr.int(p, "style:scale-to-Y") { sheet.pageSetup.fitToHeight = y }
            if let size = ODSAttr.get(p, "fo:page-width").flatMap(ODSLength.millimetres),
               let height = ODSAttr.get(p, "fo:page-height").flatMap(ODSLength.millimetres) {
                let portrait = (Swift.min(size, height) / 10, Swift.max(size, height) / 10)
                sheet.pageSetup.paperSize = paperSizes.first { abs($0.value.0 - portrait.0) < 0.2 && abs($0.value.1 - portrait.1) < 0.2 }?.key
            }
            switch ODSAttr.get(p, "style:table-centering") {
            case "both": sheet.printOptions.horizontalCentered = true; sheet.printOptions.verticalCentered = true
            case "horizontal": sheet.printOptions.horizontalCentered = true
            case "vertical": sheet.printOptions.verticalCentered = true
            default: break
            }
            let printed = (ODSAttr.get(p, "style:print") ?? "").split(separator: " ").map(String.init)
            if !printed.isEmpty {
                sheet.printOptions.gridLines = printed.contains("grid")
                sheet.printOptions.headings = printed.contains("headers")
            }
            if let v = ODSAttr.get(p, "fo:margin-left").flatMap(ODSLength.inches) { sheet.pageMargins.left = v }
            if let v = ODSAttr.get(p, "fo:margin-right").flatMap(ODSLength.inches) { sheet.pageMargins.right = v }
            // the inverse of the write: `fo:margin-top` is Excel's header margin, and the header's height is the rest
            if let v = ODSAttr.get(p, "fo:margin-top").flatMap(ODSLength.inches) {
                sheet.pageMargins.header = v
                sheet.pageMargins.top = v + (ODSAttr.get(l.header, "fo:min-height").flatMap(ODSLength.inches) ?? 0)
            }
            if let v = ODSAttr.get(p, "fo:margin-bottom").flatMap(ODSLength.inches) {
                sheet.pageMargins.footer = v
                sheet.pageMargins.bottom = v + (ODSAttr.get(l.footer, "fo:min-height").flatMap(ODSLength.inches) ?? 0)
            }
        }
        func code(_ part: String) -> String? {
            guard let regions = master.regions[part] else { return nil }
            return ODSHeaderFooter.code(left: regions["left"], center: regions["center"], right: regions["right"])
        }
        sheet.headerFooter.oddHeader = code("header")
        sheet.headerFooter.oddFooter = code("footer")
        sheet.headerFooter.evenHeader = code("header-left")
        sheet.headerFooter.evenFooter = code("footer-left")
        sheet.headerFooter.firstHeader = code("header-first")
        sheet.headerFooter.firstFooter = code("footer-first")
        sheet.headerFooter.differentOddEven = sheet.headerFooter.evenHeader != nil || sheet.headerFooter.evenFooter != nil
        sheet.headerFooter.differentFirst = sheet.headerFooter.firstHeader != nil || sheet.headerFooter.firstFooter != nil
    }

    /// `<style:master-page>` for one sheet, carrying its header and footer.
    static func masterPageXML(name: String, layout: String, _ p: Page, sheet: String, sink: ODSWarningSink) -> String {
        let hf = p.headerFooter
        func part(_ element: String, _ code: String?) -> String {
            guard let code, !code.isEmpty else { return "<style:\(element) style:display=\"false\"/>" }
            return "<style:\(element)>\(ODSHeaderFooter.regionsXML(code, sheet: sheet, sink: sink))</style:\(element)>"
        }
        var s = "<style:master-page style:name=\"\(name)\" style:page-layout-name=\"\(layout)\">"
        s += part("header", hf.oddHeader)
        // ODF's "left" page is the even one; without differentOddEven the odd header serves every page
        s += hf.differentOddEven ? part("header-left", hf.evenHeader) : "<style:header-left style:display=\"false\"/>"
        s += hf.differentFirst ? part("header-first", hf.firstHeader) : "<style:header-first style:display=\"false\"/>"
        s += part("footer", hf.oddFooter)
        s += hf.differentOddEven ? part("footer-left", hf.evenFooter) : "<style:footer-left style:display=\"false\"/>"
        s += hf.differentFirst ? part("footer-first", hf.firstFooter) : "<style:footer-first style:display=\"false\"/>"
        return s + "</style:master-page>"
    }
}

/// Excel's header / footer codes (`&L左&C中&R&P / &N`) ⇄ ODF's three regions of `text:p` with field elements.
enum ODSHeaderFooter {
    /// The three regions of one header or footer.
    static func regionsXML(_ code: String, sheet: String, sink: ODSWarningSink) -> String {
        let sections = split(code)
        var s = ""
        for (region, text) in [("left", sections.left), ("center", sections.center), ("right", sections.right)] {
            guard let text, !text.isEmpty else { continue }
            s += "<style:region-\(region)><text:p>\(fieldsXML(text, sheet: sheet, sink: sink))</text:p></style:region-\(region)>"
        }
        // a header with no section markers at all is one centred run, as Excel reads it
        if s.isEmpty, !code.isEmpty {
            s = "<style:region-center><text:p>\(fieldsXML(code, sheet: sheet, sink: sink))</text:p></style:region-center>"
        }
        return s
    }

    /// Splits `&L…&C…&R…` into its three parts. A leading run with no marker is the centre section.
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
        var chars = Array(code)
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
        chars = []
        return (left, center, right)
    }

    /// One section's text as ODF inline content: field codes become elements, everything else is literal text.
    static func fieldsXML(_ text: String, sheet: String, sink: ODSWarningSink) -> String {
        var out = ""
        var literal = ""
        var droppedFormatting = false
        func flush() {
            guard !literal.isEmpty else { return }
            out += XML.esc(literal)
            literal = ""
        }
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "&", i + 1 < chars.count else { literal.append(chars[i]); i += 1; continue }
            let code = chars[i + 1]
            i += 2
            switch code {
            case "&": literal.append("&")
            case "P": flush(); out += "<text:page-number>1</text:page-number>"
            case "N": flush(); out += "<text:page-count>99</text:page-count>"
            case "D": flush(); out += "<text:date/>"
            case "T": flush(); out += "<text:time/>"
            case "A": flush(); out += "<text:sheet-name>\(XML.esc(sheet))</text:sheet-name>"
            case "F": flush(); out += "<text:file-name text:display=\"name-and-extension\"/>"
            case "Z": flush(); out += "<text:file-name text:display=\"path\"/>"
            case "B", "I", "U", "E", "S", "X", "Y", "O", "H": droppedFormatting = true      // font toggles
            case "\"":                                                                       // &"font,style"
                droppedFormatting = true
                while i < chars.count, chars[i] != "\"" { i += 1 }
                if i < chars.count { i += 1 }
            case _ where code.isNumber:                                                      // &12 — a font size
                droppedFormatting = true
                while i < chars.count, chars[i].isNumber { i += 1 }
            case "G": sink.add(.dropped, subject: .objects, sheet: sheet, "a picture in the printed header / footer is dropped")
            default: literal.append("&"); literal.append(code)
            }
        }
        flush()
        if droppedFormatting {
            sink.add(.degraded, subject: .formatting, sheet: sheet, "font changes inside the printed header / footer are dropped; the text is kept")
        }
        return out
    }

    /// The inverse: ODF regions (already reduced to their text, with fields spelled as Excel codes) joined back
    /// into one `&L…&C…&R…` string. Empty regions are left out.
    static func code(left: String?, center: String?, right: String?) -> String? {
        var s = ""
        if let l = left, !l.isEmpty { s += "&L" + l }
        if let c = center, !c.isEmpty { s += "&C" + c }
        if let r = right, !r.isEmpty { s += "&R" + r }
        return s.isEmpty ? nil : s
    }
}
