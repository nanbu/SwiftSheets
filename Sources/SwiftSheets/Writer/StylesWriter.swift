import Foundation

/// Dedupes fonts / fills / borders / number formats into the style tables Excel expects, and hands out cellXfs indices.
final class StyleRegistry {
    private(set) var fonts: [Font] = [Font.default]
    private(set) var fills: [PatternFill] = [PatternFill(), PatternFill(patternType: .gray125)]  // Excel requires these two first
    private(set) var borders: [Border] = [Border()]
    private(set) var customFormats: [String] = []
    private var xfs: [CellStyle] = [CellStyle.default]
    private var xfIndex: [CellStyle: Int] = [CellStyle.default: 0]

    func index(for style: CellStyle) -> Int {
        if let i = xfIndex[style] { return i }
        if !fonts.contains(style.font) { fonts.append(style.font) }
        if !fills.contains(style.fill) { fills.append(style.fill) }
        if !borders.contains(style.border) { borders.append(style.border) }
        if NumberFormat.builtinIDs[style.numberFormat] == nil, !customFormats.contains(style.numberFormat) { customFormats.append(style.numberFormat) }
        xfs.append(style)
        xfIndex[style] = xfs.count - 1
        return xfs.count - 1
    }

    private func numFmtID(_ code: String) -> Int {
        if let b = NumberFormat.builtinIDs[code] { return b }
        return 164 + customFormats.firstIndex(of: code)!
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

    func xml() -> String {
        var s = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !customFormats.isEmpty {
            s += "<numFmts count=\"\(customFormats.count)\">"
            for (i, f) in customFormats.enumerated() { s += "<numFmt numFmtId=\"\(164 + i)\" formatCode=\"\(XML.esc(f))\"/>" }
            s += "</numFmts>"
        }
        s += "<fonts count=\"\(fonts.count)\">" + fonts.map { StyleRegistry.fontXML($0) }.joined() + "</fonts>"
        s += "<fills count=\"\(fills.count)\">"
        for f in fills {
            s += "<fill><patternFill"
            if f.patternType != .none { s += " patternType=\"\(f.patternType.rawValue)\"" }
            if f.foregroundColor == nil, f.backgroundColor == nil { s += "/></fill>" }
            else { s += ">" + StyleRegistry.colorXML("fgColor", f.foregroundColor) + StyleRegistry.colorXML("bgColor", f.backgroundColor) + "</patternFill></fill>" }
        }
        s += "</fills>"
        s += "<borders count=\"\(borders.count)\">"
        for b in borders {
            s += "<border\(XML.attr("diagonalUp", b.diagonalUp))\(XML.attr("diagonalDown", b.diagonalDown))>"
            for (tag, side) in [("left", b.left), ("right", b.right), ("top", b.top), ("bottom", b.bottom), ("diagonal", b.diagonal)] {
                if let st = side.style { s += "<\(tag) style=\"\(st.rawValue)\">" + StyleRegistry.colorXML("color", side.color) + "</\(tag)>" }
                else { s += "<\(tag)/>" }
            }
            s += "</border>"
        }
        s += "</borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        s += "<cellXfs count=\"\(xfs.count)\">"
        for st in xfs {
            let numFmt = numFmtID(st.numberFormat), font = fonts.firstIndex(of: st.font)!, fill = fills.firstIndex(of: st.fill)!, border = borders.firstIndex(of: st.border)!
            s += "<xf numFmtId=\"\(numFmt)\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"\(border)\" xfId=\"0\""
            if numFmt != 0 { s += " applyNumberFormat=\"1\"" }
            if font != 0 { s += " applyFont=\"1\"" }
            if fill != 0 { s += " applyFill=\"1\"" }
            if border != 0 { s += " applyBorder=\"1\"" }
            let al = st.alignment, pr = st.protection
            let hasAlign = al != Alignment.none, hasProt = pr != Protection()
            if hasAlign { s += " applyAlignment=\"1\"" }
            if hasProt { s += " applyProtection=\"1\"" }
            if hasAlign || hasProt {
                s += ">"
                if hasAlign {
                    s += "<alignment\(XML.attr("horizontal", al.horizontal?.rawValue))\(XML.attr("vertical", al.vertical?.rawValue))"
                    s += "\(XML.attr("wrapText", al.wrapText))\(XML.attr("shrinkToFit", al.shrinkToFit))"
                    if al.indent != 0 { s += XML.attr("indent", al.indent) }
                    if al.textRotation != 0 { s += XML.attr("textRotation", al.textRotation) }
                    s += "/>"
                }
                if hasProt { s += "<protection locked=\"\(pr.locked ? 1 : 0)\" hidden=\"\(pr.hidden ? 1 : 0)\"/>" }
                s += "</xf>"
            } else { s += "/>" }
        }
        s += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        return s
    }
}
