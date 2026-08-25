import Foundation
import SheetCore

/// The parts of OpenDocument that OOXML has no word for (spec Appendix B.17): calculation settings, label ranges,
/// the consolidation definition, the detective's arrows, and a cell that knows it holds money.
///
/// Everything here follows the OASIS ODF 1.3 RelaxNG schema — element names, attribute names and the values they
/// allow are taken from it, not from any one application's output.
enum ODSFeatures {
    // MARK: - Addresses

    /// `Sheet.A1:Sheet.D9` — the form ODF uses for a range in an attribute, and the one our reader parses back.
    static func address(_ range: CellRange, sheet: String) -> String {
        let prefix = String(ODSWriter.odsSheetPrefix(sheet).dropFirst())
        return "\(prefix).\(range.topLeft.a1):\(prefix).\(range.bottomRight.a1)"
    }
    /// The same for a range that already names its sheet.
    static func address(_ range: CellRange) -> String? {
        guard let sheet = range.sheet else { return nil }
        var r = range; r.sheet = nil
        return address(r, sheet: sheet)
    }
    static func address(_ ref: CellRef, sheet: String) -> String {
        "\(String(ODSWriter.odsSheetPrefix(sheet).dropFirst())).\(ref.a1)"
    }
    /// Parses one back into a sheet-qualified range.
    static func range(_ text: String) -> CellRange? { CellRange(ContentParser.excelAddress(text)) }

    // MARK: - table:calculation-settings

    /// The first child of `office:spreadsheet` (ODF 1.3 §9.4.1), before the content validations.
    ///
    /// The date origin travels here too: ODF calls it `table:null-date` and lets it be any date, while the model
    /// (like Excel) knows two. LibreOffice omits the element for the usual origin and writes it only for 1904 —
    /// so does this.
    static func calculationSettingsXML(_ wb: Workbook) -> String {
        let c = wb.calculationSettings
        let defaults = CalculationSettings()
        var attrs = ""
        if c.caseSensitive != defaults.caseSensitive { attrs += " table:case-sensitive=\"\(c.caseSensitive)\"" }
        if c.precisionAsShown != defaults.precisionAsShown { attrs += " table:precision-as-shown=\"\(c.precisionAsShown)\"" }
        if c.searchCriteriaMustApplyToWholeCell != defaults.searchCriteriaMustApplyToWholeCell {
            attrs += " table:search-criteria-must-apply-to-whole-cell=\"\(c.searchCriteriaMustApplyToWholeCell)\""
        }
        if c.automaticFindLabels != defaults.automaticFindLabels { attrs += " table:automatic-find-labels=\"\(c.automaticFindLabels)\"" }
        if c.useRegularExpressions != defaults.useRegularExpressions { attrs += " table:use-regular-expressions=\"\(c.useRegularExpressions)\"" }
        if c.useWildcards != defaults.useWildcards { attrs += " table:use-wildcards=\"\(c.useWildcards)\"" }
        if let year = c.nullYear { attrs += " table:null-year=\"\(year)\"" }

        var children = ""
        if wb.epoch == .mac1904 { children += "<table:null-date table:value-type=\"date\" table:date-value=\"1904-01-01\"/>" }
        if c.iterationEnabled || c.iterationSteps != nil || c.iterationMaximumDifference != nil {
            children += "<table:iteration table:status=\"\(c.iterationEnabled ? "enable" : "disable")\""
            if let steps = c.iterationSteps { children += " table:steps=\"\(steps)\"" }
            if let d = c.iterationMaximumDifference { children += " table:maximum-difference=\"\(XML.num(d))\"" }
            children += "/>"
        }
        guard !attrs.isEmpty || !children.isEmpty else { return "" }
        return children.isEmpty ? "<table:calculation-settings\(attrs)/>"
                                : "<table:calculation-settings\(attrs)>\(children)</table:calculation-settings>"
    }

    // MARK: - table:label-ranges

    /// Blocks of headings formulas may name directly (§9.4.9). After the content validations, before the tables.
    static func labelRangesXML(_ wb: Workbook, sink: ODSWarningSink) -> String {
        var out = ""
        for r in wb.labelRanges {
            guard let labels = address(r.labels), let data = address(r.data) else {
                sink.add(.dropped, subject: .other, "a label range names no sheet and was dropped")
                continue
            }
            out += "<table:label-range table:label-cell-range-address=\"\(XML.esc(labels))\""
            out += " table:data-cell-range-address=\"\(XML.esc(data))\""
            out += " table:orientation=\"\(r.orientation.rawValue)\"/>"
        }
        return out.isEmpty ? "" : "<table:label-ranges>\(out)</table:label-ranges>"
    }

    // MARK: - table:consolidation

    /// The stored consolidation (§9.7). In the epilogue, after the data pilots and before the DDE links.
    static func consolidationXML(_ wb: Workbook, sink: ODSWarningSink) -> String {
        guard let c = wb.consolidation else { return "" }
        let sources = c.sources.compactMap(address).joined(separator: " ")
        guard !sources.isEmpty else {
            sink.add(.dropped, subject: .other, "the consolidation names no source range and was dropped")
            return ""
        }
        var s = "<table:consolidation table:function=\"\(ODSPivot.function(c.function).name)\""
        s += " table:source-cell-range-addresses=\"\(XML.esc(sources))\""
        s += " table:target-cell-address=\"\(XML.esc(address(c.target, sheet: c.targetSheet)))\""
        if c.useLabels != .none { s += " table:use-labels=\"\(c.useLabels.rawValue)\"" }
        if c.linkToSourceData { s += " table:link-to-source-data=\"true\"" }
        return s + "/>"
    }

    // MARK: - table:detective

    /// The arrows on one cell (§9.3.2). Inside `table:table-cell`, after the annotation and before the text.
    static func detectiveXML(_ d: CellDetective, sheet: String) -> String {
        guard !d.isEmpty else { return "" }
        var s = "<table:detective>"
        for h in d.highlighted {
            s += "<table:highlighted-range"
            if let r = h.range { s += " table:cell-range-address=\"\(XML.esc(address(r) ?? address(r, sheet: sheet)))\"" }
            s += " table:direction=\"\(h.direction.rawValue)\""
            if h.containsError { s += " table:contains-error=\"true\"" }
            s += "/>"
        }
        for o in d.operations.sorted(by: { $0.index < $1.index }) {
            s += "<table:operation table:name=\"\(o.name.rawValue)\" table:index=\"\(o.index)\"/>"
        }
        return s + "</table:detective>"
    }

    // MARK: - office:currency

    /// The currency a number format names, or nil when it names none.
    ///
    /// Excel writes the currency inside the format code — `[$¥-411]#,##0.00` names it by symbol and locale,
    /// `[$USD] #,##0.00` by ISO code, `"€"#,##0.00` by a quoted symbol. ODF puts it on the *cell* as well, as data,
    /// which is the thing OOXML has no place for.
    static func currency(inFormat code: String) -> String? {
        // [$<symbol or code>-<locale>] — everything before the hyphen is the currency
        if let open = code.range(of: "[$"), let close = code[open.upperBound...].firstIndex(of: "]") {
            let body = code[open.upperBound..<close]
            let name = body.split(separator: "-", maxSplits: 1).first.map(String.init) ?? String(body)
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        // a quoted symbol, as Excel's own built-in currency formats write it
        var quoted: String?
        var inQuote = false
        var buffer = ""
        for ch in code {
            if ch == "\"" {
                if inQuote, !buffer.isEmpty, quoted == nil { quoted = buffer }
                inQuote.toggle(); buffer = ""
            } else if inQuote {
                buffer.append(ch)
            }
        }
        if let q = quoted, q.unicodeScalars.allSatisfy({ ODSFeatures.currencyScalars.contains($0) }) { return q }
        // a bare symbol
        if let symbol = code.unicodeScalars.first(where: { ODSFeatures.currencyScalars.contains($0) }) { return String(symbol) }
        return nil
    }
    /// The scalars that make a currency symbol on their own (Unicode's `Sc` category, plus the ones spreadsheets
    /// spell with letters are handled by the `[$…]` branch above).
    static let currencyScalars: CharacterSet = CharacterSet(charactersIn: "$¥€£₩₽₹¢₺₫₪₴₦﷼")
}
