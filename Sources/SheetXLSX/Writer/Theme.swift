import Foundation
import SheetCore

/// The default theme part. Excel resolves `<color theme="n"/>` and `<scheme val="minor"/>` — which the default font
/// uses, as Excel's own files do — against `xl/theme/theme1.xml`; a workbook that references a theme without
/// shipping one is the classic "we found a problem with some content" repair prompt. Files read from XLSX keep their
/// own theme (it travels as a preserved part); everything else gets this one.
enum ThemePart {
    static let partPath = "xl/theme/theme1.xml"
    static let contentType = "application/vnd.openxmlformats-officedocument.theme+xml"
    static let relationshipType = "/theme"

    /// The default theme part.
    static let xml: String = xml(for: .office)

    /// A theme part from the model's theme (B.71): the twelve scheme colours in the file's order (dk1, lt1, dk2,
    /// lt2, accent 1…6, hlink, folHlink — `Theme.colors` indexes 1, 0, 3, 2, 4…11) and the two scheme fonts;
    /// the format scheme is the minimal valid one.
    static func xml(for theme: Theme) -> String {
        let c = theme.colors.count >= 12 ? theme.colors : Theme.office.colors
        func rgb(_ i: Int) -> String { String(c[i].suffix(6)) }
        var s = "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office Theme\"><a:themeElements>"
        s += "<a:clrScheme name=\"Office\">"
        s += "<a:dk1><a:srgbClr val=\"\(rgb(1))\"/></a:dk1>"
        s += "<a:lt1><a:srgbClr val=\"\(rgb(0))\"/></a:lt1>"
        s += "<a:dk2><a:srgbClr val=\"\(rgb(3))\"/></a:dk2>"
        s += "<a:lt2><a:srgbClr val=\"\(rgb(2))\"/></a:lt2>"
        for i in 0..<6 { s += "<a:accent\(i + 1)><a:srgbClr val=\"\(rgb(4 + i))\"/></a:accent\(i + 1)>" }
        s += "<a:hlink><a:srgbClr val=\"\(rgb(10))\"/></a:hlink><a:folHlink><a:srgbClr val=\"\(rgb(11))\"/></a:folHlink></a:clrScheme>"
        s += "<a:fontScheme name=\"Office\">"
        s += "<a:majorFont><a:latin typeface=\"\(XML.esc(theme.majorFont ?? "Calibri Light"))\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
        s += "<a:minorFont><a:latin typeface=\"\(XML.esc(theme.minorFont ?? "Calibri"))\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>"
        s += "</a:fontScheme>"
        // the format scheme needs at least three entries in each list; plain solid fills and lines satisfy the schema
        s += "<a:fmtScheme name=\"Office\"><a:fillStyleLst>"
        s += String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3)
        s += "</a:fillStyleLst><a:lnStyleLst>"
        for width in [6350, 12700, 19050] {
            s += "<a:ln w=\"\(width)\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        }
        s += "</a:lnStyleLst><a:effectStyleLst>"
        s += String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3)
        s += "</a:effectStyleLst><a:bgFillStyleLst>"
        s += String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3)
        s += "</a:bgFillStyleLst></a:fmtScheme>"
        s += "</a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
        return s
    }
}
