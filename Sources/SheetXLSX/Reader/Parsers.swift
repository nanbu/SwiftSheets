import Foundation
import SheetCore

final class RelsParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var rels: [Relationship] = []
    func start(_ name: String, _ a: [String: String]) {
        if name == "Relationship", let id = a["Id"], let type = a["Type"], let target = a["Target"] {
            rels.append(Relationship(id: id, type: type, target: target, targetMode: a["TargetMode"]))
        }
    }
}

final class ContentTypesParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var defaults: [String: String] = [:]
    var overrides: [String: String] = [:]
    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "Default": if let e = a["Extension"], let t = a["ContentType"] { defaults[e.lowercased()] = t }
        case "Override": if let p = a["PartName"], let t = a["ContentType"] { overrides[p.hasPrefix("/") ? String(p.dropFirst()) : p] = t }
        default: break
        }
    }
}

/// xl/workbook.xml: sheets, names, flags — and every child the model has no home for, kept verbatim.
final class WorkbookXMLParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    struct SheetInfo { let name: String; let rId: String; let sheetId: Int?; let state: SheetState }
    static let knownChildren: Set<String> = ["workbookPr", "bookViews", "sheets", "definedNames", "calcPr"]
    var sheets: [SheetInfo] = []
    var date1904 = false
    var codeName: String?
    var workbookPrAttributes: [String: String] = [:]
    var activeTab = 0
    var definedNames: [String: String] = [:]
    /// Sheet-scoped names: localSheetId → (name → text).
    var localNames: [Int: [String: String]] = [:]
    var fragments: [XMLFragment] = []
    private var depth = 0
    private var currentName: String?
    private var currentLocal: Int?
    private var nameText = ""

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 2, !WorkbookXMLParser.knownChildren.contains(name) { beginCapture(); return }
        switch name {
        case "workbookPr":
            let v = a["date1904"]?.lowercased(); date1904 = v == "1" || v == "true"; codeName = a["codeName"]
            workbookPrAttributes = a.filter { $0.key != "date1904" && $0.key != "codeName" }
        case "workbookView": activeTab = Int(a["activeTab"] ?? "0") ?? 0
        case "sheet":
            let rId = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value ?? a["id"] ?? ""
            let state = SheetState(rawValue: a["state"] ?? "visible") ?? .visible
            sheets.append(SheetInfo(name: a["name"] ?? "", rId: rId, sheetId: Int(a["sheetId"] ?? ""), state: state))
        case "definedName": currentName = a["name"]; currentLocal = a["localSheetId"].flatMap { Int($0) }; nameText = ""
        default: break
        }
    }
    func text(_ s: String) { if currentName != nil { nameText += s } }
    func end(_ name: String) {
        depth -= 1
        guard name == "definedName", let n = currentName else { return }
        if let i = currentLocal { localNames[i, default: [:]][n] = nameText } else { definedNames[n] = nameText }
        currentName = nil
    }
    func captured(_ fragment: XMLFragment) { depth -= 1; fragments.append(fragment) }
}

/// sharedStrings.xml → values. Plain `<t>` → .text; `<r>` runs → .richText; `<rPh>` (furigana) is skipped.
final class SharedStringsParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var strings: [CellValue] = []
    private var runs: [TextRun] = []
    private var plain = ""
    private var current = ""
    private var inSI = false, inT = false, inR = false, inRPr = false, hasRuns = false
    private var skipDepth = 0
    private var runFont: Font?
    private var fontParser = FontAttributes()

    func start(_ name: String, _ a: [String: String]) {
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
    func text(_ s: String) {
        if inT, skipDepth == 0 { if inR { current += s } else { plain += s } }
    }
    func end(_ name: String) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "t": inT = false
        case "rPr": inRPr = false; runFont = fontParser.font
        case "r": runs.append(TextRun(current, font: runFont)); inR = false
        case "si":
            strings.append(hasRuns ? (runs.contains { $0.font != nil } ? .richText(runs) : .text(runs.map(\.text).joined())) : .text(plain))
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

/// styles.xml → the style tables and resolved cellXfs. Fonts / fills / borders are parsed *and* kept as raw XML,
/// and the index-referencing sections (`cellStyleXfs`, `cellStyles`, `dxfs`, `tableStyles`, `extLst`) are kept
/// verbatim, so a rewrite can keep every index the file relies on.
final class StylesParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    static let preservedSections: Set<String> = ["dxfs", "tableStyles", "extLst"]
    var numFmts: [Int: String] = [:]
    var fonts: [Font] = []
    var fills: [PatternFill] = []
    var borders: [Border] = []
    var cellXfs: [CellStyle] = []
    /// The `xfId` of each cellXf, in the same order — resolved to a style name once `cellStyles` has been read.
    var cellXfNamedStyleIDs: [Int] = []
    var cellStyleXfs: [CellStyle] = []
    var cellStyleXfXML: [String] = []
    var namedStyles: [NamedStyle] = []
    /// name → index into `cellStyleXfs`; the first entry of a duplicated name wins.
    var namedStyleXfIndex: [String: Int] = [:]
    var indexedColors: [String] = []
    var tables = StyleTables()
    var fragments: [XMLFragment] = []
    private var depth = 0
    private var section = ""
    private var fontAttrs = FontAttributes()
    private var fill = PatternFill()
    private var inPatternFill = false
    private var border = Border()
    private var side = ""
    private var xf: CellStyle?
    private var xfIsNamedStyle = false

    static func color(_ a: [String: String]) -> Color? {
        if let rgb = a["rgb"] { return .rgb(rgb.uppercased()) }
        if let t = a["theme"], let i = Int(t) { return .theme(i, tint: Double(a["tint"] ?? "0") ?? 0) }
        if let idx = a["indexed"], let i = Int(idx) { return .indexed(i) }
        if a["auto"] != nil { return .auto }
        return nil
    }

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 2, StylesParser.preservedSections.contains(name) { beginCapture(); return }
        switch name {
        case "numFmts", "fonts", "fills", "borders", "cellXfs", "cellStyleXfs", "cellStyles", "colors": section = name
        case "numFmt": if let id = Int(a["numFmtId"] ?? ""), let code = a["formatCode"] { numFmts[id] = code }
        case "rgbColor" where section == "colors": if let rgb = a["rgb"] { indexedColors.append(rgb.uppercased()) }
        case "font" where section == "fonts" && depth == 3: fontAttrs = FontAttributes(); beginCapture(deliveringEvents: true)
        case "fill" where section == "fills" && depth == 3: fill = PatternFill(); beginCapture(deliveringEvents: true)
        case "patternFill" where section == "fills":
            inPatternFill = true
            fill.patternType = PatternFill.PatternType(rawValue: a["patternType"] ?? "none") ?? .none
        case "fgColor" where inPatternFill: fill.foregroundColor = StylesParser.color(a)
        case "bgColor" where inPatternFill: fill.backgroundColor = StylesParser.color(a)
        case "border" where section == "borders" && depth == 3:
            border = Border()
            border.diagonalUp = XMLBool.isTrue(a["diagonalUp"]); border.diagonalDown = XMLBool.isTrue(a["diagonalDown"]); border.outline = XMLBool.isNotFalse(a["outline"])
            beginCapture(deliveringEvents: true)
        case "left", "right", "top", "bottom", "diagonal":
            guard section == "borders" else { return }
            side = name
            let s = Side(style: a["style"].flatMap(Side.Style.init(rawValue:)), color: nil)
            setSide(s)
        case "color" where section == "borders" && !side.isEmpty:
            var s = currentSide(); s.color = StylesParser.color(a); setSide(s)
        case "xf" where section == "cellStyleXfs" && depth == 3:
            xf = parsedXF(a)
            xfIsNamedStyle = true
            beginCapture(deliveringEvents: true)
        case "cellStyle" where section == "cellStyles":
            guard let name = a["name"] else { return }
            let xfId = Int(a["xfId"] ?? "0") ?? 0
            let style = cellStyleXfs.indices.contains(xfId) ? cellStyleXfs[xfId] : CellStyle()
            guard namedStyleXfIndex[name] == nil else { return }   // a duplicated name: the first wins
            namedStyleXfIndex[name] = xfId
            namedStyles.append(NamedStyle(name: name, style: style, builtinID: Int(a["builtinId"] ?? ""),
                                          hidden: XMLBool.isTrue(a["hidden"])))
        case "xf" where section == "cellXfs":
            cellXfNamedStyleIDs.append(Int(a["xfId"] ?? "0") ?? 0)
            xf = parsedXF(a)
        case "alignment" where xf != nil:
            xf!.alignment = Alignment(horizontal: a["horizontal"].flatMap(Alignment.Horizontal.init(rawValue:)),
                                      vertical: a["vertical"].flatMap(Alignment.Vertical.init(rawValue:)),
                                      wrapText: XMLBool.isTrue(a["wrapText"]), shrinkToFit: XMLBool.isTrue(a["shrinkToFit"]),
                                      indent: Int(a["indent"] ?? "0") ?? 0, textRotation: Int(a["textRotation"] ?? "0") ?? 0)
        case "protection" where xf != nil:
            xf!.protection = Protection(locked: XMLBool.isNotFalse(a["locked"]), hidden: XMLBool.isTrue(a["hidden"]))
        default:
            if section == "fonts" { fontAttrs.apply(name, a) }
        }
    }

    /// The formatting an `<xf>` names by index — the same resolution for `cellXfs` and `cellStyleXfs`.
    private func parsedXF(_ a: [String: String]) -> CellStyle {
        var st = CellStyle()
        let numFmt = Int(a["numFmtId"] ?? "0") ?? 0, font = Int(a["fontId"] ?? "0") ?? 0
        let fill = Int(a["fillId"] ?? "0") ?? 0, border = Int(a["borderId"] ?? "0") ?? 0
        st.numberFormat = numFmts[numFmt] ?? NumberFormat.builtin[numFmt] ?? "General"
        if fonts.indices.contains(font) { st.font = fonts[font] }
        if fills.indices.contains(fill) { st.fill = fills[fill] }
        if borders.indices.contains(border) { st.border = borders[border] }
        return st
    }

    /// Links every cellXf to the named style its `xfId` points at, once both tables have been read. An `xfId` that
    /// names nothing (out of range, or a `cellStyleXfs` entry no `cellStyle` names) leaves the cell unlinked.
    func resolveNamedStyleLinks() {
        guard !namedStyles.isEmpty else { return }
        var nameOfXf: [Int: String] = [:]
        for (name, index) in namedStyleXfIndex where nameOfXf[index] == nil { nameOfXf[index] = name }
        for i in cellXfs.indices {
            guard cellXfNamedStyleIDs.indices.contains(i), let name = nameOfXf[cellXfNamedStyleIDs[i]] else { continue }
            if name != NamedStyle.normal.name { cellXfs[i].namedStyle = name }
        }
    }

    private func currentSide() -> Side {
        switch side { case "left": border.left; case "right": border.right; case "top": border.top; case "bottom": border.bottom; default: border.diagonal }
    }
    private func setSide(_ s: Side) {
        switch side { case "left": border.left = s; case "right": border.right = s; case "top": border.top = s; case "bottom": border.bottom = s; default: border.diagonal = s }
    }

    func end(_ name: String) {
        depth -= 1
        switch name {
        case "font" where section == "fonts" && depth == 2: fonts.append(fontAttrs.font)
        case "fill" where section == "fills" && depth == 2: fills.append(fill)
        case "patternFill": inPatternFill = false
        case "left", "right", "top", "bottom", "diagonal": side = ""
        case "border" where section == "borders" && depth == 2: borders.append(border)
        case "xf" where section == "cellXfs": if let xf { cellXfs.append(xf) }; xf = nil
        case "numFmts", "fonts", "fills", "borders", "cellXfs", "cellStyleXfs", "cellStyles", "colors": section = ""
        default: break
        }
    }

    func captured(_ fragment: XMLFragment) {
        switch fragment.element {
        case "font": tables.fontXML.append(fragment.xml)
        case "fill": tables.fillXML.append(fragment.xml)
        case "border": tables.borderXML.append(fragment.xml)
        case "xf" where xfIsNamedStyle:
            cellStyleXfs.append(xf ?? CellStyle()); cellStyleXfXML.append(fragment.xml); xf = nil; xfIsNamedStyle = false
        default: depth -= 1; fragments.append(fragment)
        }
    }

    func style(_ index: Int) -> CellStyle { cellXfs.indices.contains(index) ? cellXfs[index] : CellStyle() }

    private var sharedStyles: [Int: SharedStyle] = [:]
    /// One shared instance per `xf`: a sheet's cells reference a handful of styles between them, and each of those
    /// is 384 bytes.
    func sharedStyle(_ index: Int) -> SharedStyle? {
        let s = style(index)
        guard s != .default else { return nil }
        if let existing = sharedStyles[index] { return existing }
        let made = SharedStyle(s)
        sharedStyles[index] = made
        return made
    }
    /// The number-format codes in use, custom ones only (openpyxl `stylesheet.number_formats`).
    var customNumberFormats: [String] { numFmts.sorted { $0.key < $1.key }.map(\.value).filter { !NumberFormat.isBuiltin($0) } }

    /// The source tables, for seeding a rewrite so every index stays valid.
    var styleTables: StyleTables {
        var t = tables
        t.fonts = fonts; t.fills = fills; t.borders = borders
        t.numberFormats = numFmts.filter { $0.key >= NumberFormat.firstCustomID }
        t.rootAttributes = rootAttributes
        t.cellStyleXfs = cellStyleXfs
        t.cellStyleXfXML = cellStyleXfXML.count == cellStyleXfs.count ? cellStyleXfXML : []
        t.namedStyleXfIndex = namedStyleXfIndex
        return t
    }
}

/// worksheet XML → Sheet. Children the model does not cover are kept as fragments, in document order.
final class SheetParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    static let knownChildren: Set<String> = ["sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "autoFilter", "mergeCells", "hyperlinks", "printOptions", "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks"]
    var sheet: Sheet
    private let sst: [CellValue]
    private let styles: StylesParser
    private let epoch: DateEpoch
    private let dataOnly: Bool
    private var hyperlinkRels: [String: String] = [:]

    private var depth = 0
    private var currentRow = -1, lastColumn = -1   // 0-based; a <row> without r= follows the previous one
    private var cellRef: CellRef?
    private var cellType = "", cellStyle = 0
    private var vText = "", fText = "", isText = ""
    private var inV = false, inF = false, inIS = false, inT = false
    private var isRuns: [TextRun] = [], isHasRuns = false, inR = false, inRPr = false, runText = "", runFont: FontAttributes?
    private var skipDepth = 0
    private var formulaType: String?
    private var formulaRef: String?
    private var sharedFormulaIndex: String?
    private var sharedFormulas: [String: (FormulaExpr, CellRef)] = [:]
    private var headerFooterPart: String?
    private var headerFooterText = ""
    private var breakAxis: String?
    private var filterColumn: FilterColumn?
    private var inSortState = false

    init(name: String, sst: [CellValue], styles: StylesParser, epoch: DateEpoch, dataOnly: Bool, rels: [Relationship]) {
        self.sheet = Sheet(name: name); self.sst = sst; self.styles = styles; self.epoch = epoch; self.dataOnly = dataOnly
        for r in rels where r.type.hasSuffix("/hyperlink") { hyperlinkRels[r.id] = r.target }
    }

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 2, !SheetParser.knownChildren.contains(name) { beginCapture(); return }
        if skipDepth > 0 { skipDepth += 1; return }
        switch name {
        case "outlinePr": sheet.properties.summaryBelow = XMLBool.isNotFalse(a["summaryBelow"]); sheet.properties.summaryRight = XMLBool.isNotFalse(a["summaryRight"])
        case "tabColor": sheet.properties.tabColor = StylesParser.color(a)
        case "dimension": sheet.declaredDimension = a["ref"].flatMap(CellRange.init)
        case "sheetPr": sheet.properties.codeName = a["codeName"]; sheet.properties.filterMode = a["filterMode"].map { $0 == "1" || $0 == "true" }
        case "pageSetUpPr": sheet.properties.fitToPage = a["fitToPage"].map { $0 == "1" || $0 == "true" }
        case "sheetView":
            sheet.view.showGridLines = XMLBool.isNotFalse(a["showGridLines"])
            sheet.view.zoomScale = Int(a["zoomScale"] ?? "100") ?? 100
            sheet.view.tabSelected = XMLBool.isTrue(a["tabSelected"])
        case "selection": if let ac = a["activeCell"] { sheet.view.activeCell = ac }; if let sq = a["sqref"] { sheet.view.sqref = sq }
        case "sheetFormatPr":
            var f = SheetFormatProperties()
            f.baseColWidth = Int(a["baseColWidth"] ?? "") ?? f.baseColWidth; f.defaultColWidth = Double(a["defaultColWidth"] ?? "")
            f.defaultRowHeight = Double(a["defaultRowHeight"] ?? "") ?? f.defaultRowHeight
            f.customHeight = XMLBool.isTrue(a["customHeight"]); f.zeroHeight = XMLBool.isTrue(a["zeroHeight"])
            sheet.sheetFormat = f
        case "pane": if a["state"] == "frozen" || a["state"] == "frozenSplit", let tl = a["topLeftCell"] { sheet.freezePanes = CellRef(tl) }
        case "col":
            guard let mn = Int(a["min"] ?? ""), let mx = Int(a["max"] ?? ""), mn >= 1 else { return }
            var d = ColumnDimension()
            d.width = Double(a["width"] ?? ""); d.hidden = XMLBool.isTrue(a["hidden"]); d.outlineLevel = Int(a["outlineLevel"] ?? "0") ?? 0
            d.collapsed = XMLBool.isTrue(a["collapsed"]); d.bestFit = XMLBool.isTrue(a["bestFit"])
            if let st = Int(a["style"] ?? ""), st > 0 { d.style = styles.style(st) }
            for c in (mn - 1)...(Swift.min(mx, mn + 16383) - 1) { sheet.table.columnDimensions[c] = d }
        case "row":
            // `r` may be written with an exponent ("1.048573e6"); a non-integral value is invalid (openpyxl raises).
            if let r = a["r"] { guard let n = SheetParser.rowNumber(r) else { fail(.malformedPart(path: "worksheet", detail: "invalid row number \(r)")); return }; currentRow = n - 1 } else { currentRow += 1 }
            lastColumn = -1
            sheet.table.nextAppendRow = currentRow + 1
            var d = RowDimension()
            if XMLBool.isTrue(a["customHeight"]) || a["ht"] != nil { d.height = Double(a["ht"] ?? "") }
            d.hidden = XMLBool.isTrue(a["hidden"]); d.outlineLevel = Int(a["outlineLevel"] ?? "0") ?? 0; d.collapsed = XMLBool.isTrue(a["collapsed"])
            d.thickTop = XMLBool.isTrue(a["thickTop"]); d.thickBottom = XMLBool.isTrue(a["thickBot"])
            if let st = Int(a["s"] ?? ""), st > 0 { d.style = styles.style(st) }
            if !d.isDefault { sheet.table.rowDimensions[currentRow] = d }
        case "c":
            if let r = a["r"], let ref = CellRef(r) { cellRef = ref; if ref.row != currentRow { currentRow = ref.row } }
            else { cellRef = CellRef(row: currentRow, col: lastColumn + 1) }
            lastColumn = cellRef!.col
            cellType = a["t"] ?? "n"; cellStyle = Int(a["s"] ?? "0") ?? 0
            vText = ""; fText = ""; isText = ""; formulaType = nil; formulaRef = nil; sharedFormulaIndex = nil
            var cell = Cell()
            cell.sharedStyle = styles.sharedStyle(cellStyle)
            sheet.table.store(cell, at: cellRef!)   // every <c> exists, even without a value
        case "v": inV = true
        case "f": inF = true; formulaType = a["t"]; formulaRef = a["ref"]; sharedFormulaIndex = a["si"]
        case "is": inIS = true; isRuns = []; isHasRuns = false
        case "r" where inIS: inR = true; isHasRuns = true; runText = ""; runFont = nil
        case "rPr" where inIS: inRPr = true; runFont = FontAttributes()
        case "t" where inIS: inT = true
        case "rPh": skipDepth = 1
        case _ where inRPr: runFont?.apply(name, a)
        case "mergeCell": if let r = a["ref"].flatMap(CellRange.init) { sheet.table.merges.append(r) }
        case "autoFilter":
            sheet.autoFilter = a["ref"].flatMap(CellRange.init)
            // the conditions inside are read into the model *and* captured: `captured(_:)` throws the capture away
            // unless the file uses a filter kind the model cannot say
            if depth == 2 { beginCapture(deliveringEvents: true) }
        case "filterColumn":
            filterColumn = FilterColumn(column: Int(a["colId"] ?? "") ?? 0, buttonHidden: XMLBool.isTrue(a["hiddenButton"]))
        case "filters" where filterColumn != nil: filterColumn!.includesBlanks = XMLBool.isTrue(a["blank"])
        case "filter" where filterColumn != nil: if let v = a["val"] { filterColumn!.values.append(v) }
        case "customFilters" where filterColumn != nil: filterColumn!.matchesAllConditions = XMLBool.isTrue(a["and"])
        case "customFilter" where filterColumn != nil:
            let op = FilterCondition.Comparison(rawValue: a["operator"] ?? "equal") ?? .equal
            filterColumn!.conditions.append(FilterCondition(op, a["val"] ?? ""))
        case "sortState":
            guard let r = a["ref"].flatMap(CellRange.init) else { return }
            inSortState = true
            sheet.sortState = SortState(range: r, caseSensitive: XMLBool.isTrue(a["caseSensitive"]),
                                        byColumn: XMLBool.isTrue(a["columnSort"]))
        case "sortCondition" where inSortState:
            if let r = a["ref"].flatMap(CellRange.init) {
                sheet.sortState?.conditions.append(SortCondition(range: r, descending: XMLBool.isTrue(a["descending"])))
            }
        case "hyperlink":
            // `ref` may be a range ("B4:B7"); the link goes on its first cell. A link on a merged cell goes to the anchor.
            if var ref = a["ref"].flatMap(CellRange.init)?.topLeft {
                if let m = sheet.table.mergedRange(containing: ref) { ref = m.topLeft }
                let rid = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value
                var link: Hyperlink?
                if let rid, let target = hyperlinkRels[rid] { link = Hyperlink(target: target, tooltip: a["tooltip"], display: a["display"]) }
                else if let loc = a["location"] { link = Hyperlink(target: loc, tooltip: a["tooltip"], display: a["display"], isInternal: true) }
                else if let display = a["display"] { link = Hyperlink(target: display, tooltip: a["tooltip"], display: display) }   // neither r:id nor location: Excel shows the display text
                if let link { var c = sheet.table[cell: ref]; c.hyperlink = link; sheet.table.store(c, at: ref) }
            }
        case "printOptions":
            sheet.printOptions.horizontalCentered = XMLBool.isTrue(a["horizontalCentered"]); sheet.printOptions.verticalCentered = XMLBool.isTrue(a["verticalCentered"])
            sheet.printOptions.headings = XMLBool.isTrue(a["headings"]); sheet.printOptions.gridLines = XMLBool.isTrue(a["gridLines"])
        case "pageMargins":
            var m = PageMargins()
            m.left = Double(a["left"] ?? "") ?? m.left; m.right = Double(a["right"] ?? "") ?? m.right; m.top = Double(a["top"] ?? "") ?? m.top
            m.bottom = Double(a["bottom"] ?? "") ?? m.bottom; m.header = Double(a["header"] ?? "") ?? m.header; m.footer = Double(a["footer"] ?? "") ?? m.footer
            sheet.pageMargins = m
        case "pageSetup":
            var p = PageSetup()
            p.orientation = a["orientation"].flatMap(PageSetup.Orientation.init(rawValue:)); p.paperSize = Int(a["paperSize"] ?? "")
            p.fitToWidth = Int(a["fitToWidth"] ?? ""); p.fitToHeight = Int(a["fitToHeight"] ?? ""); p.scale = Int(a["scale"] ?? "")
            p.firstPageNumber = Int(a["firstPageNumber"] ?? ""); p.useFirstPageNumber = a["useFirstPageNumber"].map { $0 == "1" }
            sheet.pageSetup = p
            sheet.preserved.pageSetupRelationshipId = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value
        case "headerFooter":
            sheet.headerFooter.differentOddEven = XMLBool.isTrue(a["differentOddEven"])
            sheet.headerFooter.differentFirst = XMLBool.isTrue(a["differentFirst"])
            sheet.headerFooter.scaleWithDoc = XMLBool.isNotFalse(a["scaleWithDoc"])
            sheet.headerFooter.alignWithMargins = XMLBool.isNotFalse(a["alignWithMargins"])
        case "oddHeader", "oddFooter", "evenHeader", "evenFooter", "firstHeader", "firstFooter":
            headerFooterPart = name; headerFooterText = ""
        case "brk":
            guard let id = Int(a["id"] ?? ""), id > 0 else { return }
            if breakAxis == "rowBreaks" { sheet.rowBreaks.append(id) } else if breakAxis == "colBreaks" { sheet.columnBreaks.append(id) }
        case "rowBreaks", "colBreaks": breakAxis = name
        default: break
        }
    }

    func text(_ s: String) {
        if inV { vText += s } else if inF { fText += s } else if inT, skipDepth == 0 { if inR { runText += s } else { isText += s } }
        else if headerFooterPart != nil { headerFooterText += s }
    }

    func end(_ name: String) {
        depth -= 1
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
            var cell = sheet.table[cell: ref]
            cell.value = value(at: ref)
            sheet.table.store(cell, at: ref)
            cellRef = nil
        case "oddHeader", "oddFooter", "evenHeader", "evenFooter", "firstHeader", "firstFooter":
            switch name {
            case "oddHeader": sheet.headerFooter.oddHeader = headerFooterText
            case "oddFooter": sheet.headerFooter.oddFooter = headerFooterText
            case "evenHeader": sheet.headerFooter.evenHeader = headerFooterText
            case "evenFooter": sheet.headerFooter.evenFooter = headerFooterText
            case "firstHeader": sheet.headerFooter.firstHeader = headerFooterText
            default: sheet.headerFooter.firstFooter = headerFooterText
            }
            headerFooterPart = nil; headerFooterText = ""
        case "rowBreaks", "colBreaks": breakAxis = nil
        case "filterColumn": if let c = filterColumn { sheet.filterColumns.append(c) }; filterColumn = nil
        case "sortState": inSortState = false
        case "sheetData": if !sheet.table.cells.isEmpty { sheet.table.nextAppendRow = sheet.table.rowCount }   // cells, not trailing empty rows, decide where `append` continues
        case "mergeCells": for r in sheet.table.merges { sheet.table.cleanMergedRange(r) }   // openpyxl `bind_merged_cells`
        default: break
        }
    }

    /// Filter kinds the model does not carry. A file that uses one keeps its `<autoFilter>` verbatim; everything
    /// else is regenerated from `Sheet.filterColumns` / `sortState`.
    static let unmodelledFilters = ["colorFilter", "iconFilter", "dynamicFilter", "top10", "dateGroupItem", "extLst"]

    func captured(_ fragment: XMLFragment) {
        if fragment.element == "autoFilter" {
            // a bare ref, or conditions the model now carries, are regenerated; the exotic kinds are not
            guard SheetParser.unmodelledFilters.contains(where: { fragment.xml.contains("<" + $0) }) else { return }
            sheet.hasUnmodelledFilters = true
        } else {
            // the source's own validations are kept verbatim; reading does not model them (spec B.13)
            // an empty <dataValidations count="0"/> is not a rule — openpyxl reports none either
            if fragment.element == "dataValidations", fragment.xml.contains("<dataValidation ") { sheet.hasUnmodelledValidations = true }
            depth -= 1
        }
        sheet.preserved.fragments.append(fragment)
    }

    /// "23" → 23, "1.048573e6" → 1048573; nil for non-integral values and for anything past the sheet's last row
    /// (a bare `Int(d)` on "1e300" would trap — malformed input must never take the process down, spec §12).
    static func rowNumber(_ text: String) -> Int? {
        if let i = Int(text) { return i >= 1 && i <= CellRef.maxRow + 1 ? i : nil }
        guard let d = Double(text), d == d.rounded(), d >= 1, d <= Double(CellRef.maxRow + 1) else { return nil }
        return Int(d)
    }

    private func value(at ref: CellRef) -> CellValue? {
        let cached = cachedValue()
        if dataOnly { return cached }
        if !fText.isEmpty {
            let expr = FormulaExpr.parse(fText, dialect: .xlsx)
            if formulaType == "shared", let si = sharedFormulaIndex { sharedFormulas[si] = (expr, ref) }
            if formulaType == "array", let r = formulaRef, let range = CellRange(r) { sheet.table.arrayFormulas[ref] = range }
            return .formula(expr, cached: cached)
        }
        if formulaType == "shared", let si = sharedFormulaIndex, let (master, origin) = sharedFormulas[si] {
            // a follower of a shared formula: the master's formula translated by the offset (what Excel shows)
            let dr = ref.row - origin.row, dc = ref.col - origin.col
            let translated = master.mapped { e in
                if case .ref(let r, let s, let ar, let ac) = e, s == nil { return .ref(CellRef(row: ar ? r.row : r.row + dr, col: ac ? r.col : r.col + dc), sheet: s, absRow: ar, absCol: ac) }
                return e
            }
            return .formula(translated, cached: cached)
        }
        return cached
    }

    private func cachedValue() -> CellValue? {
        switch cellType {
        case "s":
            guard let i = Int(vText.trimmingCharacters(in: .whitespaces)), sst.indices.contains(i) else { return nil }
            return sst[i]
        case "inlineStr":
            if isHasRuns { return isRuns.contains { $0.font != nil } ? .richText(isRuns) : .text(isRuns.map(\.text).joined()) }
            return .text(isText)
        case "str": return .text(vText)
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
            return .number(Decimal(string: raw, locale: nil).flatMap { $0.isNaN ? nil : $0 } ?? Decimal(d))
        }
    }
}

final class CorePropertiesParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var props = DocumentProperties()
    private var buf = ""
    func start(_ name: String, _ a: [String: String]) { buf = "" }
    func text(_ s: String) { buf += s }
    func end(_ name: String) {
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
    }
}

/// docProps/app.xml — only the generating application is of interest.
final class AppPropertiesParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var application: String?
    var version: String?
    private var buf = ""
    func start(_ name: String, _ a: [String: String]) { buf = "" }
    func text(_ s: String) { buf += s }
    func end(_ name: String) {
        switch name {
        case "Application": application = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        case "AppVersion": version = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
    }
}


/// xsd:boolean: "1" / "true" are true, "0" / "false" are false (LibreOffice writes the words, Excel the digits).
enum XMLBool {
    static func isTrue(_ v: String?) -> Bool { v == "1" || v == "true" }
    static func isNotFalse(_ v: String?) -> Bool { v != "0" && v != "false" }
}
