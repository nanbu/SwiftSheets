import Foundation

/// The default theme part. Excel resolves `<color theme="n"/>` and `<scheme val="minor"/>` — which the default font
/// uses, as Excel's own files do — against `xl/theme/theme1.xml`; a workbook that references a theme without
/// shipping one is the classic "we found a problem with some content" repair prompt. Files read from XLSX keep their
/// own theme (it travels as a preserved part); everything else gets this one.
enum Theme {
    static let partPath = "xl/theme/theme1.xml"
    static let contentType = "application/vnd.openxmlformats-officedocument.theme+xml"
    static let relationshipType = "/theme"

    /// The twelve scheme colours, in the order `<color theme="n"/>` indexes them
    /// (0 = background 1 / lt1, 1 = text 1 / dk1, 2 = background 2 / lt2, 3 = text 2 / dk2, then the accents).
    static let xml: String = {
        var s = "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office Theme\"><a:themeElements>"
        s += "<a:clrScheme name=\"Office\">"
        s += "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>"
        s += "<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
        s += "<a:dk2><a:srgbClr val=\"44546A\"/></a:dk2>"
        s += "<a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>"
        for (i, colour) in ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"].enumerated() {
            s += "<a:accent\(i + 1)><a:srgbClr val=\"\(colour)\"/></a:accent\(i + 1)>"
        }
        s += "<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink></a:clrScheme>"
        s += "<a:fontScheme name=\"Office\">"
        s += "<a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
        s += "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>"
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
    }()
}
