import Foundation
import SheetCore

/// Dedupes fonts / fills / borders / number formats into the style tables Excel expects, and hands out cellXfs
/// indices. When seeded with a source file's tables, the original entries keep their positions (and their raw XML),
/// so `cellStyleXfs`, `dxfs` / `tableStyles` and `<col style>` references written back verbatim stay valid.
final class StyleRegistry {
    private(set) var fonts: [Font] = [Font.default]
    private(set) var fills: [Fill] = [.pattern(PatternFill()), .pattern(PatternFill(patternType: .gray125))]  // Excel requires these two first
    private(set) var borders: [Border] = [Border()]
    private var fontXML: [String] = []
    private var fillXML: [String] = []
    private var borderXML: [String] = []
    private var fontIndex: [Font: Int] = [:]
    private var fillIndex: [Fill: Int] = [:]
    private var borderIndex: [Border: Int] = [:]
    /// Custom number formats: code → id (ids ≥ 164).
    private(set) var customFormats: [String: Int] = [:]
    private var nextCustomID = NumberFormat.firstCustomID
    private var xfs: [CellStyle] = [CellStyle.default]
    private var xfIndex: [CellStyle: Int] = [CellStyle.default: 0]
    var indexedColors: [String] = []
    /// Verbatim sections of the source styles.xml.
    var fragments: [XMLFragment] = []
    /// The source `cellStyleXfs`, entry by entry. Every one is kept whether or not a `cellStyle` names it: the
    /// table is addressed by index, so dropping an unnamed entry would renumber the ones after it.
    private var sourceCellStyleXfs: [CellStyle] = []
    private var sourceCellStyleXfXML: [String] = []
    private var sourceNamedStyleXfIndex: [String: Int] = [:]
    /// The differential formats, seeded from the source and appended to. Conditional formats, tables and colour
    /// filters address them by index, so a source entry never moves and its raw XML is re-emitted unless the
    /// model's copy of it has been edited.
    private var dxfs: [DifferentialStyle] = []
    private var dxfXML: [String] = []
    private var sourceDxfs: [DifferentialStyle] = []
    private var dxfIndex: [DifferentialStyle: Int] = [:]
    /// The workbook's named styles, in order; set before `xml()`.
    var namedStyles: [NamedStyle] = [.normal]
    var rootAttributes: [String: String] = [:]

    /// `keepCellXfs` keeps every source `cellXfs` entry at its index (a sheet carried as bytes names its
    /// formatting by that index); otherwise the table is rebuilt from the cells that are written.
    init(seed: StyleTables? = nil, keepCellXfs: Bool = false) {
        if let seed, seed.fills.count >= 2 {
            fonts = seed.fonts; fills = seed.fills; borders = seed.borders
            fontXML = seed.fontXML.count == seed.fonts.count ? seed.fontXML : []
            fillXML = seed.fillXML.count == seed.fills.count ? seed.fillXML : []
            borderXML = seed.borderXML.count == seed.borders.count ? seed.borderXML : []
            for (id, code) in seed.numberFormats { customFormats[code] = id }
            nextCustomID = Swift.max(NumberFormat.firstCustomID, (seed.numberFormats.keys.max() ?? 0) + 1)
            rootAttributes = seed.rootAttributes
            sourceCellStyleXfs = seed.cellStyleXfs
            sourceCellStyleXfXML = seed.cellStyleXfXML.count == seed.cellStyleXfs.count ? seed.cellStyleXfXML : []
            sourceNamedStyleXfIndex = seed.namedStyleXfIndex
            sourceDxfs = seed.dxfs
            dxfs = seed.dxfs
            dxfXML = seed.dxfXML.count == seed.dxfs.count ? seed.dxfXML : seed.dxfs.map(StyleRegistry.dxfXML)
            if fonts.isEmpty { fonts = [Font.default] }
            if borders.isEmpty { borders = [Border()] }
        }
        for (i, f) in fonts.enumerated() where fontIndex[f] == nil { fontIndex[f] = i }
        for (i, f) in fills.enumerated() where fillIndex[f] == nil { fillIndex[f] = i }
        for (i, b) in borders.enumerated() where borderIndex[b] == nil { borderIndex[b] = i }
        for (i, d) in dxfs.enumerated() where dxfIndex[d] == nil { dxfIndex[d] = i }
        // index 0 of cellXfs is the default style; its font / fill / border are whatever sits at index 0 of each table
        xfs = [CellStyle.default]; xfIndex = [CellStyle.default: 0]
        if keepCellXfs, let seed, !seed.cellXfs.isEmpty {
            xfs = []; xfIndex = [:]
            for style in seed.cellXfs {
                _ = fontID(style.font); _ = fillID(style.fill); _ = borderID(style.border); _ = numFmtID(style.numberFormat)
                xfs.append(style)
                if xfIndex[style] == nil { xfIndex[style] = xfs.count - 1 }
            }
            if xfIndex[CellStyle.default] == nil { xfs.append(CellStyle.default); xfIndex[CellStyle.default] = xfs.count - 1 }
        }
    }

    private func fontID(_ f: Font) -> Int {
        if let i = fontIndex[f] { return i }
        fonts.append(f); fontIndex[f] = fonts.count - 1
        if !fontXML.isEmpty { fontXML.append(StyleRegistry.fontXML(f)) }
        return fonts.count - 1
    }
    private func fillID(_ f: Fill) -> Int {
        if let i = fillIndex[f] { return i }
        fills.append(f); fillIndex[f] = fills.count - 1
        if !fillXML.isEmpty { fillXML.append(StyleRegistry.fillXML(f)) }
        return fills.count - 1
    }
    private func borderID(_ b: Border) -> Int {
        if let i = borderIndex[b] { return i }
        borders.append(b); borderIndex[b] = borders.count - 1
        if !borderXML.isEmpty { borderXML.append(StyleRegistry.borderXML(b)) }
        return borders.count - 1
    }

    /// Brings every named style's own formatting into the tables. This has to happen before `xml()` starts
    /// emitting sections: the `<fonts>` element is written before `cellStyleXfs` is built, so a font first seen
    /// there would arrive too late to be listed.
    func registerNamedStyles(_ styles: [NamedStyle]) {
        namedStyles = styles
        for named in styles {
            _ = fontID(named.style.font); _ = fillID(named.style.fill); _ = borderID(named.style.border)
            _ = numFmtID(named.style.numberFormat)
        }
    }

    /// Brings the workbook's own list of differential formats into the table: an entry the model has edited since
    /// it was read replaces the source's, and any beyond the source's count are appended in order.
    func applyDifferentialStyles(_ list: [DifferentialStyle]) {
        for (i, d) in list.enumerated() {
            if dxfs.indices.contains(i) {
                if dxfs[i] != d { replaceDXF(at: i, with: d) }
            } else {
                dxfs.append(d)
                dxfXML.append(StyleRegistry.dxfXML(d))
                if dxfIndex[d] == nil { dxfIndex[d] = dxfs.count - 1 }
            }
        }
    }

    /// The `xf` index of a cell's formatting, by the shared style object the cell points at when it has one: the
    /// same object answers from a small identity table instead of hashing a 384-byte style per cell.
    private var sharedIndex: [ObjectIdentifier: (style: SharedStyle, index: Int)] = [:]
    func index(for cell: Cell) -> Int {
        guard let shared = cell.sharedStyle else { return index(for: cell.style) }
        let id = ObjectIdentifier(shared)
        if let known = sharedIndex[id], known.style === shared { return known.index }
        let i = index(for: shared.style)
        sharedIndex[id] = (shared, i)
        return i
    }

    func index(for style: CellStyle) -> Int {
        if let i = xfIndex[style] { return i }
        _ = fontID(style.font); _ = fillID(style.fill); _ = borderID(style.border)
        _ = numFmtID(style.numberFormat)
        xfs.append(style)
        xfIndex[style] = xfs.count - 1
        return xfs.count - 1
    }

    /// The index of a differential format, adding it when it is new.
    ///
    /// `preferring` is where the style sat in the source file. An untouched entry keeps that index — and with it
    /// the raw XML the file had, including whatever the model cannot say — rather than being deduped onto some
    /// other entry that happens to parse the same way.
    func dxfID(_ style: DifferentialStyle, preferring source: Int? = nil) -> Int {
        if let source, sourceDxfs.indices.contains(source), sourceDxfs[source] == style { return source }
        if let i = dxfIndex[style] { return i }
        dxfs.append(style)
        dxfXML.append(StyleRegistry.dxfXML(style))
        dxfIndex[style] = dxfs.count - 1
        return dxfs.count - 1
    }

    /// Replaces the entry `index` holds — for a source style the model has since edited.
    func replaceDXF(at index: Int, with style: DifferentialStyle) {
        guard dxfs.indices.contains(index) else { return }
        dxfs[index] = style
        dxfXML[index] = StyleRegistry.dxfXML(style)
        if dxfIndex[style] == nil { dxfIndex[style] = index }
    }

    /// The differential formats as they will be written — index-addressable, so a caller can look one up.
    var differentialStyles: [DifferentialStyle] { dxfs }

    /// One `<dxf>`. CT_Dxf's children in schema order: font, numFmt, fill, alignment, border, protection.
    static func dxfXML(_ d: DifferentialStyle) -> String {
        var s = "<dxf>"
        if let f = d.font, !f.isEmpty {
            s += "<font>"
            if let v = f.bold { s += "<b val=\"\(v ? 1 : 0)\"/>" }
            if let v = f.italic { s += "<i val=\"\(v ? 1 : 0)\"/>" }
            if let v = f.strikethrough { s += "<strike val=\"\(v ? 1 : 0)\"/>" }
            if let v = f.underline { s += "<u val=\"\(v.rawValue)\"/>" }
            if let v = f.vertAlign { s += "<vertAlign val=\"\(XML.esc(v))\"/>" }
            if let v = f.size { s += "<sz val=\"\(XML.num(v))\"/>" }
            s += colorXML("color", f.color)
            if let v = f.name { s += "<name val=\"\(XML.esc(v))\"/>" }
            s += "</font>"
        }
        if let code = d.numberFormat {
            s += "<numFmt numFmtId=\"\(NumberFormat.builtinID(code) ?? NumberFormat.firstCustomID)\" formatCode=\"\(XML.esc(code))\"/>"
        }
        if let fill = d.fill { s += "<fill>" + fillBodyXML(fill) + "</fill>" }
        if let al = d.alignment {
            s += "<alignment\(XML.attr("horizontal", al.horizontal?.rawValue))\(XML.attr("vertical", al.vertical?.rawValue))"
            s += "\(XML.attr("wrapText", al.wrapText))\(XML.attr("shrinkToFit", al.shrinkToFit))"
            if al.indent != 0 { s += XML.attr("indent", al.indent) }
            if al.textRotation != 0 { s += XML.attr("textRotation", al.textRotation) }
            s += "/>"
        }
        if let b = d.border { s += borderXML(b) }
        if let p = d.protection { s += "<protection locked=\"\(p.locked ? 1 : 0)\" hidden=\"\(p.hidden ? 1 : 0)\"/>" }
        return s + "</dxf>"
    }

    private func numFmtID(_ code: String) -> Int {
        // locale-dependent builtins (the East Asian date formats) are written out in full so every reader agrees
        if let b = NumberFormat.builtinIDs[code], !NumberFormat.localeDependentIDs.contains(b) { return b }
        if let id = customFormats[code] { return id }
        customFormats[code] = nextCustomID
        nextCustomID += 1
        return customFormats[code]!
    }

    static func colorXML(_ tag: String, _ c: Color?) -> String {
        guard let c else { return "" }
        switch c {
        case .rgb(let v): return "<\(tag) rgb=\"\(v)\"/>"
        case .theme(let i, let tint): return tint == 0 ? "<\(tag) theme=\"\(i)\"/>" : "<\(tag) theme=\"\(i)\" tint=\"\(tint)\"/>"
        case .indexed(let i): return "<\(tag) indexed=\"\(i)\"/>"
        case .auto: return "<\(tag) auto=\"1\"/>"
        }
    }

    /// CT_Font's children in the order the schema lists them (b, i, strike, u, vertAlign, sz, color, name, family,
    /// charset, scheme) — Excel accepts nothing else without offering to repair the file.
    static func fontXML(_ f: Font, tag: String = "font", nameTag: String = "name") -> String {
        var s = "<\(tag)>"
        if f.bold { s += "<b val=\"1\"/>" }
        if f.italic { s += "<i val=\"1\"/>" }
        if f.strikethrough { s += "<strike val=\"1\"/>" }
        if let u = f.underline { s += "<u val=\"\(u.rawValue)\"/>" }
        if let v = f.vertAlign { s += "<vertAlign val=\"\(v)\"/>" }
        if let sz = f.size { s += "<sz val=\"\(XML.num(sz))\"/>" }
        s += colorXML("color", f.color)
        if let n = f.name { s += "<\(nameTag) val=\"\(XML.esc(n))\"/>" }
        if let fam = f.family { s += "<family val=\"\(fam)\"/>" }
        if let cs = f.charset { s += "<charset val=\"\(cs)\"/>" }
        if let sch = f.scheme { s += "<scheme val=\"\(sch)\"/>" }
        return s + "</\(tag)>"
    }

    static func fillXML(_ f: Fill) -> String { "<fill>" + fillBodyXML(f) + "</fill>" }

    /// The `<patternFill>` / `<gradientFill>` inside a `<fill>` or a `<dxf>`.
    static func fillBodyXML(_ f: Fill) -> String {
        switch f {
        case .pattern(let p):
            var s = "<patternFill"
            if p.patternType != .none { s += " patternType=\"\(p.patternType.rawValue)\"" }
            if p.foregroundColor == nil, p.backgroundColor == nil { return s + "/>" }
            return s + ">" + colorXML("fgColor", p.foregroundColor) + colorXML("bgColor", p.backgroundColor) + "</patternFill>"
        case .gradient(let g):
            var s = "<gradientFill"
            if g.kind != .linear { s += " type=\"\(g.kind.rawValue)\"" }
            if g.degree != 0 { s += " degree=\"\(XML.num(g.degree))\"" }
            for (name, v) in [("left", g.left), ("right", g.right), ("top", g.top), ("bottom", g.bottom)] where v != 0 {
                s += " \(name)=\"\(XML.num(v))\""
            }
            guard !g.stops.isEmpty else { return s + "/>" }
            return s + ">" + g.stops.map { "<stop position=\"\(XML.num($0.position))\">" + colorXML("color", $0.color) + "</stop>" }.joined() + "</gradientFill>"
        }
    }

    static func borderXML(_ b: Border) -> String {
        var s = "<border\(XML.attr("diagonalUp", b.diagonalUp))\(XML.attr("diagonalDown", b.diagonalDown))\(b.outline ? "" : " outline=\"0\"")>"
        for (tag, side) in [("left", b.left), ("right", b.right), ("top", b.top), ("bottom", b.bottom), ("diagonal", b.diagonal)] {
            if let st = side.style { s += "<\(tag) style=\"\(st.rawValue)\">" + colorXML("color", side.color) + "</\(tag)>" }
            else { s += "<\(tag)/>" }
        }
        return s + "</border>"
    }

    /// `cellStyleXfs` for the output, and where each named style sits in it.
    ///
    /// The source table is the seed and never renumbers: a name the file already had keeps its index, and its raw
    /// `<xf>` is re-emitted unless the model's copy of that style has been edited since. New names are appended.
    private func namedStyleTable() -> (entries: [String], xfIDOfName: [String: Int]) {
        var entries = sourceCellStyleXfXML.isEmpty
            ? sourceCellStyleXfs.map { namedStyleXF($0) }
            : sourceCellStyleXfXML
        var xfIDOfName: [String: Int] = [:]
        for named in namedStyles {
            if let i = sourceNamedStyleXfIndex[named.name], entries.indices.contains(i) {
                if !sourceCellStyleXfs.indices.contains(i) || sourceCellStyleXfs[i] != named.style { entries[i] = namedStyleXF(named.style) }
                xfIDOfName[named.name] = i
            } else {
                entries.append(namedStyleXF(named.style))
                xfIDOfName[named.name] = entries.count - 1
            }
        }
        if entries.isEmpty { entries = [namedStyleXF(.default)]; xfIDOfName[NamedStyle.normal.name] = 0 }
        return (entries, xfIDOfName)
    }

    /// One `cellStyleXfs` entry. Excel reads a named style's formatting from here, so the alignment goes in too.
    private func namedStyleXF(_ style: CellStyle) -> String {
        let numFmt = numFmtID(style.numberFormat), font = fontID(style.font), fill = fillID(style.fill), border = borderID(style.border)
        var s = "<xf numFmtId=\"\(numFmt)\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"\(border)\""
        if numFmt != 0 { s += " applyNumberFormat=\"1\"" }
        if font != 0 { s += " applyFont=\"1\"" }
        if fill != 0 { s += " applyFill=\"1\"" }
        if border != 0 { s += " applyBorder=\"1\"" }
        guard style.alignment != Alignment.none else { return s + "/>" }
        let al = style.alignment
        s += " applyAlignment=\"1\"><alignment\(XML.attr("horizontal", al.horizontal?.rawValue))\(XML.attr("vertical", al.vertical?.rawValue))"
        s += "\(XML.attr("wrapText", al.wrapText))\(XML.attr("shrinkToFit", al.shrinkToFit))"
        if al.indent != 0 { s += XML.attr("indent", al.indent) }
        if al.textRotation != 0 { s += XML.attr("textRotation", al.textRotation) }
        return s + "/></xf>"
    }

    /// CT_Stylesheet child order.
    static let sectionOrder = ["numFmts", "fonts", "fills", "borders", "cellStyleXfs", "cellXfs", "cellStyles", "dxfs", "tableStyles", "colors", "extLst"]

    func xml() -> String {
        var sections: [String: String] = [:]
        if !customFormats.isEmpty {
            let sorted = customFormats.sorted { $0.value < $1.value }
            sections["numFmts"] = "<numFmts count=\"\(sorted.count)\">" + sorted.map { "<numFmt numFmtId=\"\($0.value)\" formatCode=\"\(XML.esc($0.key))\"/>" }.joined() + "</numFmts>"
        }
        let fontParts = fontXML.count == fonts.count ? fontXML : fonts.map { StyleRegistry.fontXML($0) }
        sections["fonts"] = "<fonts count=\"\(fonts.count)\">" + fontParts.joined() + "</fonts>"
        let fillParts = fillXML.count == fills.count ? fillXML : fills.map(StyleRegistry.fillXML)
        sections["fills"] = "<fills count=\"\(fills.count)\">" + fillParts.joined() + "</fills>"
        let borderParts = borderXML.count == borders.count ? borderXML : borders.map(StyleRegistry.borderXML)
        sections["borders"] = "<borders count=\"\(borders.count)\">" + borderParts.joined() + "</borders>"
        let (styleXfs, xfIDOfName) = namedStyleTable()
        sections["cellStyleXfs"] = "<cellStyleXfs count=\"\(styleXfs.count)\">" + styleXfs.joined() + "</cellStyleXfs>"
        var xfXML = "<cellXfs count=\"\(xfs.count)\">"
        for st in xfs {
            let numFmt = numFmtID(st.numberFormat), font = fontID(st.font), fill = fillID(st.fill), border = borderID(st.border)
            let xfId = st.namedStyle.flatMap { xfIDOfName[$0] } ?? 0
            xfXML += "<xf numFmtId=\"\(numFmt)\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"\(border)\" xfId=\"\(xfId)\""
            if numFmt != 0 { xfXML += " applyNumberFormat=\"1\"" }
            if font != 0 { xfXML += " applyFont=\"1\"" }
            if fill != 0 { xfXML += " applyFill=\"1\"" }
            if border != 0 { xfXML += " applyBorder=\"1\"" }
            let al = st.alignment, pr = st.protection
            let hasAlign = al != Alignment.none, hasProt = pr != Protection()
            if hasAlign { xfXML += " applyAlignment=\"1\"" }
            if hasProt { xfXML += " applyProtection=\"1\"" }
            if hasAlign || hasProt {
                xfXML += ">"
                if hasAlign {
                    xfXML += "<alignment\(XML.attr("horizontal", al.horizontal?.rawValue))\(XML.attr("vertical", al.vertical?.rawValue))"
                    xfXML += "\(XML.attr("wrapText", al.wrapText))\(XML.attr("shrinkToFit", al.shrinkToFit))"
                    if al.indent != 0 { xfXML += XML.attr("indent", al.indent) }
                    if al.textRotation != 0 { xfXML += XML.attr("textRotation", al.textRotation) }
                    xfXML += "/>"
                }
                if hasProt { xfXML += "<protection locked=\"\(pr.locked ? 1 : 0)\" hidden=\"\(pr.hidden ? 1 : 0)\"/>" }
                xfXML += "</xf>"
            } else { xfXML += "/>" }
        }
        sections["cellXfs"] = xfXML + "</cellXfs>"
        let styleList = namedStyles.isEmpty ? [NamedStyle.normal] : namedStyles
        // one statement at a time rather than one expression: the same concatenation written inline is more
        // than some toolchains will type-check
        var cellStyles = "<cellStyles count=\"\(styleList.count)\">"
        for named in styleList {
            cellStyles += "<cellStyle name=\"\(XML.esc(named.name))\" xfId=\"\(xfIDOfName[named.name] ?? 0)\""
            if let builtin = named.builtinID { cellStyles += " builtinId=\"\(builtin)\"" }
            if named.hidden { cellStyles += " hidden=\"1\"" }
            cellStyles += "/>"
        }
        sections["cellStyles"] = cellStyles + "</cellStyles>"
        if !dxfs.isEmpty { sections["dxfs"] = "<dxfs count=\"\(dxfs.count)\">" + dxfXML.joined() + "</dxfs>" }
        if !indexedColors.isEmpty {
            sections["colors"] = "<colors><indexedColors>" + indexedColors.map { "<rgbColor rgb=\"\(XML.esc($0))\"/>" }.joined() + "</indexedColors></colors>"
        }
        for f in fragments { sections[f.element] = f.xml }   // verbatim sections from the source win
        var s = "<styleSheet" + XMLWriter.rootAttributes(rootAttributes, defaults: ["xmlns": XMLWriter.nsMain]) + ">"
        for name in StyleRegistry.sectionOrder { if let x = sections[name] { s += x } }
        return s + "</styleSheet>"
    }
}
