import Foundation

struct Relationship { let id: String; let type: String; let target: String; let mode: String? }

final class RelsParser: SAXParser {
    var rels: [Relationship] = []
    override func start(_ name: String, _ a: [String: String]) {
        if name == "Relationship", let id = a["Id"], let type = a["Type"], let target = a["Target"] {
            rels.append(Relationship(id: id, type: type, target: target, mode: a["TargetMode"]))
        }
    }
}

final class WorkbookXMLParser: SAXParser {
    struct SheetInfo { let name: String; let rId: String; let state: SheetState }
    var sheets: [SheetInfo] = []
    var date1904 = false
    var codeName: String?
    var activeTab = 0
    var definedNames: [String: String] = [:]
    /// Sheet-scoped names: localSheetId → (name → text).
    var localNames: [Int: [String: String]] = [:]
    private var currentName: String?
    private var currentLocal: Int?
    private var nameText = ""

    override func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "workbookPr": let v = a["date1904"]?.lowercased(); date1904 = v == "1" || v == "true"; codeName = a["codeName"]
        case "workbookView": activeTab = Int(a["activeTab"] ?? "0") ?? 0
        case "sheet":
            let rId = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value ?? a["id"] ?? ""
            let state = SheetState(rawValue: a["state"] ?? "visible") ?? .visible
            sheets.append(SheetInfo(name: a["name"] ?? "", rId: rId, state: state))
        case "definedName": currentName = a["name"]; currentLocal = a["localSheetId"].flatMap { Int($0) }; nameText = ""
        default: break
        }
    }
    override func text(_ s: String) { if currentName != nil { nameText += s } }
    override func end(_ name: String) {
        guard name == "definedName", let n = currentName else { return }
        if let i = currentLocal { localNames[i, default: [:]][n] = nameText } else { definedNames[n] = nameText }
        currentName = nil
    }
}

/// sharedStrings.xml → values. Plain `<t>` → .string; `<r>` runs → .richText; `<rPh>` (furigana) is skipped.
final class SharedStringsParser: SAXParser {
    var strings: [CellValue] = []
    private var runs: [TextRun] = []
    private var plain = ""
    private var current = ""
    private var inSI = false, inT = false, inR = false, inRPr = false, hasRuns = false
    private var skipDepth = 0
    private var runFont: Font?
    private var fontParser = FontAttributes()

    override func start(_ name: String, _ a: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        switch name {
        case "si": inSI = true; runs = []; plain = ""; hasRuns = false
        case "rPh": skipDepth = 1
        case "r": inR = true; current = ""; runFont = nil; hasRuns = true
        case "rPr": inRPr = true; fontParser = FontAttributes()
        case "t" where inSI: inT = true
        default:
            if inRPr { fontParser.apply(name, a) }
        }
    }
    override func text(_ s: String) {
        if inT, skipDepth == 0 { if inR { current += s } else { plain += s } }
    }
    override func end(_ name: String) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "t": inT = false
        case "rPr": inRPr = false; runFont = fontParser.font
        case "r": runs.append(TextRun(current, font: runFont)); inR = false
        case "si":
            strings.append(hasRuns ? (runs.contains { $0.font != nil } ? .richText(runs) : .string(runs.map(\.text).joined())) : .string(plain))
            inSI = false
        default: break
        }
    }
}

/// Accumulates `<font>` / `<rPr>` children into a Font.
struct FontAttributes {
    var font = Font()
    var touched = false
    mutating func apply(_ name: String, _ a: [String: String]) {
        touched = true
        switch name {
        case "b": font.bold = a["val"].map { $0 != "0" && $0 != "false" } ?? true
        case "i": font.italic = a["val"].map { $0 != "0" && $0 != "false" } ?? true
        case "strike": font.strikethrough = a["val"].map { $0 != "0" && $0 != "false" } ?? true
        case "u": let v = a["val"] ?? "single"; font.underline = v == "none" ? nil : (Font.Underline(rawValue: v) ?? .single)   // val="none" means no underline
        case "sz": font.size = Double(a["val"] ?? "")
        case "name", "rFont": font.name = a["val"]
        case "family": font.family = Int(a["val"] ?? "")
        case "scheme": font.scheme = a["val"] == "none" ? nil : a["val"]
        case "vertAlign": font.vertAlign = a["val"] == "none" ? nil : a["val"]
        case "charset": font.charset = Int(a["val"] ?? "")
        case "color": font.color = StylesParser.color(a)
        default: break
        }
    }
}

/// styles.xml → the style tables and resolved cellXfs.
final class StylesParser: SAXParser {
    var numFmts: [Int: String] = [:]
    var fonts: [Font] = []
    var fills: [PatternFill] = []
    var borders: [Border] = []
    var cellXfs: [CellStyle] = []
    var indexedColors: [String] = []
    private var section = ""
    private var fontAttrs = FontAttributes()
    private var fill = PatternFill()
    private var inPatternFill = false
    private var border = Border()
    private var side = ""
    private var xf: CellStyle?
    private var xfNumFmt = 0, xfFont = 0, xfFill = 0, xfBorder = 0

    static func color(_ a: [String: String]) -> Color? {
        if let rgb = a["rgb"] { return .rgb(rgb.uppercased()) }
        if let t = a["theme"], let i = Int(t) { return .theme(i, tint: Double(a["tint"] ?? "0") ?? 0) }
        if let idx = a["indexed"], let i = Int(idx) { return .indexed(i) }
        if a["auto"] != nil { return .auto }
        return nil
    }

    override func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "numFmts", "fonts", "fills", "borders", "cellXfs", "cellStyleXfs", "dxfs", "colors": section = name
        case "numFmt": if let id = Int(a["numFmtId"] ?? ""), let code = a["formatCode"] { numFmts[id] = code }
        case "rgbColor" where section == "colors": if let rgb = a["rgb"] { indexedColors.append(rgb.uppercased()) }
        case "font" where section == "fonts": fontAttrs = FontAttributes()
        case "fill" where section == "fills": fill = PatternFill()
        case "patternFill" where section == "fills":
            inPatternFill = true
            fill.patternType = PatternFill.PatternType(rawValue: a["patternType"] ?? "none") ?? .none
        case "fgColor" where inPatternFill: fill.foregroundColor = StylesParser.color(a)
        case "bgColor" where inPatternFill: fill.backgroundColor = StylesParser.color(a)
        case "border" where section == "borders":
            border = Border()
            border.diagonalUp = a["diagonalUp"] == "1"; border.diagonalDown = a["diagonalDown"] == "1"; border.outline = a["outline"] != "0"
        case "left", "right", "top", "bottom", "diagonal":
            guard section == "borders" else { return }
            side = name
            let s = Side(style: a["style"].flatMap(Side.Style.init(rawValue:)), color: nil)
            setSide(s)
        case "color" where section == "borders" && !side.isEmpty:
            var s = currentSide(); s.color = StylesParser.color(a); setSide(s)
        case "xf" where section == "cellXfs":
            var st = CellStyle()
            xfNumFmt = Int(a["numFmtId"] ?? "0") ?? 0
            xfFont = Int(a["fontId"] ?? "0") ?? 0
            xfFill = Int(a["fillId"] ?? "0") ?? 0
            xfBorder = Int(a["borderId"] ?? "0") ?? 0
            st.numberFormat = numFmts[xfNumFmt] ?? NumberFormat.builtin[xfNumFmt] ?? "General"
            if fonts.indices.contains(xfFont) { st.font = fonts[xfFont] }
            if fills.indices.contains(xfFill) { st.fill = fills[xfFill] }
            if borders.indices.contains(xfBorder) { st.border = borders[xfBorder] }
            xf = st
        case "alignment" where xf != nil:
            xf!.alignment = Alignment(horizontal: a["horizontal"].flatMap(Alignment.Horizontal.init(rawValue:)),
                                      vertical: a["vertical"].flatMap(Alignment.Vertical.init(rawValue:)),
                                      wrapText: a["wrapText"] == "1", shrinkToFit: a["shrinkToFit"] == "1",
                                      indent: Int(a["indent"] ?? "0") ?? 0, textRotation: Int(a["textRotation"] ?? "0") ?? 0)
        case "protection" where xf != nil:
            xf!.protection = Protection(locked: a["locked"] != "0", hidden: a["hidden"] == "1")
        default:
            if section == "fonts" { fontAttrs.apply(name, a) }
        }
    }

    private func currentSide() -> Side {
        switch side { case "left": border.left; case "right": border.right; case "top": border.top; case "bottom": border.bottom; default: border.diagonal }
    }
    private func setSide(_ s: Side) {
        switch side { case "left": border.left = s; case "right": border.right = s; case "top": border.top = s; case "bottom": border.bottom = s; default: border.diagonal = s }
    }

    override func end(_ name: String) {
        switch name {
        case "font" where section == "fonts": fonts.append(fontAttrs.font)
        case "fill" where section == "fills": fills.append(fill)
        case "patternFill": inPatternFill = false
        case "left", "right", "top", "bottom", "diagonal": side = ""
        case "border" where section == "borders": borders.append(border)
        case "xf" where section == "cellXfs": if let xf { cellXfs.append(xf) }; xf = nil
        case "numFmts", "fonts", "fills", "borders", "cellXfs", "cellStyleXfs", "dxfs", "colors": section = ""
        default: break
        }
    }

    func style(_ index: Int) -> CellStyle { cellXfs.indices.contains(index) ? cellXfs[index] : CellStyle() }
    /// The number-format codes in use, custom ones only (openpyxl `stylesheet.number_formats`).
    var customNumberFormats: [String] { numFmts.sorted { $0.key < $1.key }.map(\.value).filter { !NumberFormat.isBuiltin($0) } }
}

/// worksheet XML → Worksheet.
final class SheetParser: SAXParser {
    let ws: Worksheet
    private let sst: [CellValue]
    private let styles: StylesParser
    private let epoch: DateEpoch
    private let dataOnly: Bool
    private let rels: [Relationship]

    private var currentRow = 0, lastColumn = 0
    private var cellRef: CellReference?
    private var cellType = "", cellStyle = 0
    private var vText = "", fText = "", isText = ""
    private var inV = false, inF = false, inIS = false, inT = false
    private var isRuns: [TextRun] = [], isHasRuns = false, inR = false, inRPr = false, runText = "", runFont: FontAttributes?
    private var skipDepth = 0
    private var hyperlinkRels: [String: String] = [:]

    init(ws: Worksheet, sst: [CellValue], styles: StylesParser, epoch: DateEpoch, dataOnly: Bool, rels: [Relationship]) {
        self.ws = ws; self.sst = sst; self.styles = styles; self.epoch = epoch; self.dataOnly = dataOnly; self.rels = rels
        for r in rels where r.type.hasSuffix("/hyperlink") { hyperlinkRels[r.id] = r.target }
    }

    override func start(_ name: String, _ a: [String: String]) {
        if skipDepth > 0 { skipDepth += 1; return }
        switch name {
        case "outlinePr": ws.properties.summaryBelow = a["summaryBelow"] != "0"; ws.properties.summaryRight = a["summaryRight"] != "0"
        case "tabColor": ws.properties.tabColor = StylesParser.color(a)
        case "dimension": ws.declaredDimension = a["ref"].flatMap(CellRange.init)
        case "sheetPr": ws.properties.codeName = a["codeName"]; ws.properties.filterMode = a["filterMode"].map { $0 == "1" || $0 == "true" }
        case "pageSetUpPr": ws.properties.fitToPage = a["fitToPage"].map { $0 == "1" || $0 == "true" }
        case "sheetView":
            ws.view.showGridLines = a["showGridLines"] != "0"
            ws.view.zoomScale = Int(a["zoomScale"] ?? "100") ?? 100
            ws.view.tabSelected = a["tabSelected"] == "1"
        case "selection": if let ac = a["activeCell"] { ws.view.activeCell = ac }; if let sq = a["sqref"] { ws.view.sqref = sq }
        case "sheetFormatPr":
            var f = SheetFormat()
            f.baseColWidth = Int(a["baseColWidth"] ?? "") ?? f.baseColWidth; f.defaultColWidth = Double(a["defaultColWidth"] ?? "")
            f.defaultRowHeight = Double(a["defaultRowHeight"] ?? "") ?? f.defaultRowHeight
            f.customHeight = a["customHeight"] == "1"; f.zeroHeight = a["zeroHeight"] == "1"
            ws.sheetFormat = f
        case "pane": if a["state"] == "frozen" || a["state"] == "frozenSplit", let tl = a["topLeftCell"] { ws.freezePanes = CellReference(tl) }
        case "col":
            guard let mn = Int(a["min"] ?? ""), let mx = Int(a["max"] ?? "") else { return }
            var d = ColumnDimension()
            d.width = Double(a["width"] ?? ""); d.hidden = a["hidden"] == "1"; d.outlineLevel = Int(a["outlineLevel"] ?? "0") ?? 0
            d.collapsed = a["collapsed"] == "1"; d.bestFit = a["bestFit"] == "1"
            if let st = Int(a["style"] ?? ""), st > 0 { d.style = styles.style(st) }
            for c in mn...min(mx, mn + 16383) { ws.columnDimensions[CellReference.columnLetter(c)] = d }
        case "row":
            // `r` may be written with an exponent ("1.048573e6"); a non-integral value is invalid (openpyxl raises).
            if let r = a["r"] { guard let n = SheetParser.rowNumber(r) else { fail(SheetsError(.invalid, "invalid row number \(r)")); return }; currentRow = n } else { currentRow += 1 }
            lastColumn = 0
            ws.currentRow = currentRow
            var d = RowDimension()
            if a["customHeight"] == "1" || a["ht"] != nil { d.height = Double(a["ht"] ?? "") }
            d.hidden = a["hidden"] == "1"; d.outlineLevel = Int(a["outlineLevel"] ?? "0") ?? 0; d.collapsed = a["collapsed"] == "1"
            d.thickTop = a["thickTop"] == "1"; d.thickBottom = a["thickBot"] == "1"
            if let st = Int(a["s"] ?? ""), st > 0 { d.style = styles.style(st) }
            if !d.isDefault { ws.rowDimensions[currentRow] = d }
        case "c":
            if let r = a["r"], let ref = CellReference(r) { cellRef = ref; if ref.row != currentRow { currentRow = ref.row } }
            else { cellRef = CellReference(column: lastColumn + 1, row: currentRow) }
            lastColumn = cellRef!.column
            cellType = a["t"] ?? "n"; cellStyle = Int(a["s"] ?? "0") ?? 0
            vText = ""; fText = ""; isText = ""
            let cell = ws.cell(row: cellRef!.row, column: cellRef!.column)   // every <c> exists, even without a value
            cell.style = styles.style(cellStyle)
        case "v": inV = true
        case "f": inF = true
        case "is": inIS = true; isRuns = []; isHasRuns = false
        case "r" where inIS: inR = true; isHasRuns = true; runText = ""; runFont = nil
        case "rPr" where inIS: inRPr = true; runFont = FontAttributes()
        case "t" where inIS: inT = true
        case "rPh": skipDepth = 1
        case _ where inRPr: runFont?.apply(name, a)
        case "mergeCell": if let r = a["ref"].flatMap(CellRange.init) { ws.mergedCells.append(r) }
        case "autoFilter": ws.autoFilter = a["ref"].flatMap(CellRange.init)
        case "hyperlink":
            // `ref` may be a range ("B4:B7"); the link goes on its first cell. A link on a merged cell goes to the anchor.
            if var ref = a["ref"].flatMap(CellRange.init)?.topLeft {
                if let m = ws.mergedRange(containing: ref) { ref = m.topLeft }
                let rid = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value
                if let rid, let target = hyperlinkRels[rid] { ws[ref].hyperlink = Hyperlink(target: target, tooltip: a["tooltip"], display: a["display"]) }
                else if let loc = a["location"] { ws[ref].hyperlink = Hyperlink(target: loc, tooltip: a["tooltip"], display: a["display"], isInternal: true) }
                else if let display = a["display"] { ws[ref].hyperlink = Hyperlink(target: display, tooltip: a["tooltip"], display: display) }   // neither r:id nor location: Excel shows the display text
            }
        case "printOptions":
            ws.printOptions.horizontalCentered = a["horizontalCentered"] == "1"; ws.printOptions.verticalCentered = a["verticalCentered"] == "1"
            ws.printOptions.headings = a["headings"] == "1"; ws.printOptions.gridLines = a["gridLines"] == "1"
        case "pageMargins":
            var m = PageMargins()
            m.left = Double(a["left"] ?? "") ?? m.left; m.right = Double(a["right"] ?? "") ?? m.right; m.top = Double(a["top"] ?? "") ?? m.top
            m.bottom = Double(a["bottom"] ?? "") ?? m.bottom; m.header = Double(a["header"] ?? "") ?? m.header; m.footer = Double(a["footer"] ?? "") ?? m.footer
            ws.pageMargins = m
        case "pageSetup":
            var p = PageSetup()
            p.orientation = a["orientation"].flatMap(PageSetup.Orientation.init(rawValue:)); p.paperSize = Int(a["paperSize"] ?? "")
            p.fitToWidth = Int(a["fitToWidth"] ?? ""); p.fitToHeight = Int(a["fitToHeight"] ?? ""); p.scale = Int(a["scale"] ?? "")
            p.firstPageNumber = Int(a["firstPageNumber"] ?? ""); p.useFirstPageNumber = a["useFirstPageNumber"].map { $0 == "1" }
            ws.pageSetup = p
        default: break
        }
    }

    override func text(_ s: String) {
        if inV { vText += s } else if inF { fText += s } else if inT, skipDepth == 0 { if inR { runText += s } else { isText += s } }
    }

    override func end(_ name: String) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "v": inV = false
        case "f": inF = false
        case "t": inT = false
        case "rPr" where inIS: inRPr = false
        case "r" where inIS: isRuns.append(TextRun(runText, font: runFont?.font)); inR = false
        case "is": inIS = false
        case "c":
            guard let ref = cellRef else { return }
            ws.cell(row: ref.row, column: ref.column).value = value()
            cellRef = nil
        case "sheetData": if !ws.cells.isEmpty { ws.currentRow = ws.maxRow }   // cells, not trailing empty rows, decide where `append` continues
        case "mergeCells": for r in ws.mergedCells { ws.cleanMergedRange(r) }   // openpyxl `bind_merged_cells`
        default: break
        }
    }

    /// "23" → 23, "1.048573e6" → 1048573; nil for non-integral values.
    static func rowNumber(_ text: String) -> Int? {
        if let i = Int(text) { return i }
        guard let d = Double(text), d == d.rounded(), d >= 1 else { return nil }
        return Int(d)
    }

    private func value() -> CellValue? {
        let cached = cachedValue()
        if !fText.isEmpty, !dataOnly { return .formula("=" + fText, cached: cached.map(CellValueBox.init)) }
        return cached
    }

    private func cachedValue() -> CellValue? {
        switch cellType {
        case "s":
            guard let i = Int(vText.trimmingCharacters(in: .whitespaces)), sst.indices.contains(i) else { return nil }
            return sst[i]
        case "inlineStr":
            if isHasRuns { return isRuns.contains { $0.font != nil } ? .richText(isRuns) : .string(isRuns.map(\.text).joined()) }
            return .string(isText)
        case "str": return .string(vText)
        case "b": return .bool(vText.trimmingCharacters(in: .whitespaces) == "1")
        case "e": return .error(vText)
        case "d": return ExcelDate.fromISO8601(vText)
        default:
            let raw = vText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let d = Double(raw) else { return nil }
            let fmt = styles.style(cellStyle).numberFormat
            if NumberFormat.isTimedeltaFormat(fmt) { return ExcelDate.durationFromSerial(d).map { .duration($0) } }
            if NumberFormat.isDateFormat(fmt) { return ExcelDate.fromSerial(d, epoch: epoch) }
            if !raw.contains("."), !raw.contains("E"), !raw.contains("e"), let i = Int(raw) { return .integer(i) }
            return .number(d)
        }
    }
}

final class CorePropertiesParser: SAXParser {
    var props = DocumentProperties()
    private var current = ""
    private var buf = ""
    override func start(_ name: String, _ a: [String: String]) { current = name; buf = "" }
    override func text(_ s: String) { buf += s }
    override func end(_ name: String) {
        let f = ISO8601DateFormatter()
        switch name {
        case "creator": props.creator = buf
        case "lastModifiedBy": props.lastModifiedBy = buf
        case "title": props.title = buf
        case "subject": props.subject = buf
        case "description": props.description = buf
        case "keywords": props.keywords = buf
        case "category": props.category = buf
        case "contentStatus": props.contentStatus = buf
        case "identifier": props.identifier = buf
        case "language": props.language = buf
        case "version": props.version = buf
        case "revision": props.revision = buf
        case "created": props.created = f.date(from: buf.trimmingCharacters(in: .whitespacesAndNewlines))
        case "modified": props.modified = f.date(from: buf.trimmingCharacters(in: .whitespacesAndNewlines))
        case "lastPrinted": props.lastPrinted = f.date(from: buf.trimmingCharacters(in: .whitespacesAndNewlines))
        default: break
        }
        current = ""
    }
}
