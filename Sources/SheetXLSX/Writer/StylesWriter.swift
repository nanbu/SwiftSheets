import Foundation
import SheetCore

/// Dedupes fonts / fills / borders / number formats into the style tables Excel expects, and hands out cellXfs
/// indices. When seeded with a source file's tables, the original entries keep their positions (and their raw XML),
/// so `cellStyleXfs`, `dxfs` / `tableStyles` and `<col style>` references written back verbatim stay valid.
final class StyleRegistry {
    private(set) var fonts: [Font] = [Font.default]
    private(set) var fills: [PatternFill] = [PatternFill(), PatternFill(patternType: .gray125)]  // Excel requires these two first
    private(set) var borders: [Border] = [Border()]
    private var fontXML: [String] = []
    private var fillXML: [String] = []
    private var borderXML: [String] = []
    private var fontIndex: [Font: Int] = [:]
    private var fillIndex: [PatternFill: Int] = [:]
    private var borderIndex: [Border: Int] = [:]
    /// Custom number formats: code → id (ids ≥ 164).
    private(set) var customFormats: [String: Int] = [:]
    private var nextCustomID = NumberFormat.firstCustomID
    private var xfs: [CellStyle] = [CellStyle.default]
    private var xfIndex: [CellStyle: Int] = [CellStyle.default: 0]
    var indexedColors: [String] = []
    /// Verbatim sections of the source styles.xml.
    var fragments: [XMLFragment] = []
    var rootAttributes: [String: String] = [:]

    init(seed: StyleTables? = nil) {
        if let seed, seed.fills.count >= 2 {
            fonts = seed.fonts; fills = seed.fills; borders = seed.borders
            fontXML = seed.fontXML.count == seed.fonts.count ? seed.fontXML : []
            fillXML = seed.fillXML.count == seed.fills.count ? seed.fillXML : []
            borderXML = seed.borderXML.count == seed.borders.count ? seed.borderXML : []
            for (id, code) in seed.numberFormats { customFormats[code] = id }
            nextCustomID = Swift.max(NumberFormat.firstCustomID, (seed.numberFormats.keys.max() ?? 0) + 1)
            rootAttributes = seed.rootAttributes
            if fonts.isEmpty { fonts = [Font.default] }
            if borders.isEmpty { borders = [Border()] }
        }
        for (i, f) in fonts.enumerated() where fontIndex[f] == nil { fontIndex[f] = i }
        for (i, f) in fills.enumerated() where fillIndex[f] == nil { fillIndex[f] = i }
        for (i, b) in borders.enumerated() where borderIndex[b] == nil { borderIndex[b] = i }
        // index 0 of cellXfs is the default style; its font / fill / border are whatever sits at index 0 of each table
        xfs = [CellStyle.default]; xfIndex = [CellStyle.default: 0]
    }

    private func fontID(_ f: Font) -> Int {
        if let i = fontIndex[f] { return i }
        fonts.append(f); fontIndex[f] = fonts.count - 1
        if !fontXML.isEmpty { fontXML.append(StyleRegistry.fontXML(f)) }
        return fonts.count - 1
    }
    private func fillID(_ f: PatternFill) -> Int {
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

    func index(for style: CellStyle) -> Int {
        if let i = xfIndex[style] { return i }
        _ = fontID(style.font); _ = fillID(style.fill); _ = borderID(style.border)
        _ = numFmtID(style.numberFormat)
        xfs.append(style)
        xfIndex[style] = xfs.count - 1
        return xfs.count - 1
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

    static func fontXML(_ f: Font, tag: String = "font", nameTag: String = "name") -> String {
        var s = "<\(tag)>"
        if let cs = f.charset { s += "<charset val=\"\(cs)\"/>" }
        if f.bold { s += "<b val=\"1\"/>" }
        if f.italic { s += "<i val=\"1\"/>" }
        if f.strikethrough { s += "<strike val=\"1\"/>" }
        if let u = f.underline { s += "<u val=\"\(u.rawValue)\"/>" }
        if let v = f.vertAlign { s += "<vertAlign val=\"\(v)\"/>" }
        if let sz = f.size { s += "<sz val=\"\(XML.num(sz))\"/>" }
        s += colorXML("color", f.color)
        if let n = f.name { s += "<\(nameTag) val=\"\(XML.esc(n))\"/>" }
        if let fam = f.family { s += "<family val=\"\(fam)\"/>" }
        if let sch = f.scheme { s += "<scheme val=\"\(sch)\"/>" }
        return s + "</\(tag)>"
    }

    static func fillXML(_ f: PatternFill) -> String {
        var s = "<fill><patternFill"
        if f.patternType != .none { s += " patternType=\"\(f.patternType.rawValue)\"" }
        if f.foregroundColor == nil, f.backgroundColor == nil { return s + "/></fill>" }
        return s + ">" + colorXML("fgColor", f.foregroundColor) + colorXML("bgColor", f.backgroundColor) + "</patternFill></fill>"
    }

    static func borderXML(_ b: Border) -> String {
        var s = "<border\(XML.attr("diagonalUp", b.diagonalUp))\(XML.attr("diagonalDown", b.diagonalDown))\(b.outline ? "" : " outline=\"0\"")>"
        for (tag, side) in [("left", b.left), ("right", b.right), ("top", b.top), ("bottom", b.bottom), ("diagonal", b.diagonal)] {
            if let st = side.style { s += "<\(tag) style=\"\(st.rawValue)\">" + colorXML("color", side.color) + "</\(tag)>" }
            else { s += "<\(tag)/>" }
        }
        return s + "</border>"
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
        sections["cellStyleXfs"] = "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        var xfXML = "<cellXfs count=\"\(xfs.count)\">"
        for st in xfs {
            let numFmt = numFmtID(st.numberFormat), font = fontID(st.font), fill = fillID(st.fill), border = borderID(st.border)
            xfXML += "<xf numFmtId=\"\(numFmt)\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"\(border)\" xfId=\"0\""
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
        sections["cellStyles"] = "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        if !indexedColors.isEmpty {
            sections["colors"] = "<colors><indexedColors>" + indexedColors.map { "<rgbColor rgb=\"\(XML.esc($0))\"/>" }.joined() + "</indexedColors></colors>"
        }
        for f in fragments { sections[f.element] = f.xml }   // verbatim sections from the source win
        var s = "<styleSheet" + XMLWriter.rootAttributes(rootAttributes, defaults: ["xmlns": XMLWriter.nsMain]) + ">"
        for name in StyleRegistry.sectionOrder { if let x = sections[name] { s += x } }
        return s + "</styleSheet>"
    }
}
