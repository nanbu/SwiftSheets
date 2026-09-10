import Foundation
import SheetCore

/// The worksheet's `<extLst>` as a preserved fragment (spec Appendices B.79, B.82): one extension is taken out
/// when the model regenerates it, and the regenerated extensions are spliced back in beside whatever else was
/// there. Each helper works on the XML text — the fragment is bytes the model does not otherwise interpret.
enum ExtensionList {
    /// The fragment without the extension of `uri`; nil when nothing else was in it. The fragment untouched when
    /// it holds no such extension.
    static func removing(uri: String, from fragment: XMLFragment) -> XMLFragment? {
        var xml = fragment.xml
        while let uriRange = xml.range(of: uri) {
            guard let open = xml.range(of: "<[A-Za-z0-9_]*:?ext[ \\t\\r\\n]", options: [.regularExpression, .backwards], range: xml.startIndex..<uriRange.lowerBound),
                  let close = xml.range(of: "</[A-Za-z0-9_]*:?ext[ \\t\\r\\n]*>", options: .regularExpression, range: uriRange.upperBound..<xml.endIndex)
            else { break }
            xml.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if xml.range(of: "<[A-Za-z0-9_]*:?ext[ \\t\\r\\n]", options: .regularExpression) == nil { return nil }
        return XMLFragment(element: fragment.element, xml: xml)
    }

    /// Whether the fragment holds an extension of `uri`.
    static func holds(uri: String, _ fragment: XMLFragment) -> Bool { fragment.element == "extLst" && fragment.xml.contains(uri) }

    /// The extensions spliced into a preserved `extLst`, or a fresh `extLst` around them.
    static func splicing(_ extensions: [String], into fragment: XMLFragment?) -> XMLFragment {
        let ext = extensions.joined()
        if let fragment, let close = fragment.xml.range(of: "</[A-Za-z0-9_]*:?extLst[ \\t\\r\\n]*>", options: [.regularExpression, .backwards]) {
            return XMLFragment(element: "extLst", xml: String(fragment.xml[..<close.lowerBound]) + ext + String(fragment.xml[close.lowerBound...]))
        }
        return XMLFragment(element: "extLst", xml: "<extLst>" + ext + "</extLst>")
    }

    /// The fragment inside a root that declares the prefixes a worksheet root declares, so a parser can read it.
    static func wrapped(_ fragment: XMLFragment) -> Data {
        Data(("<root xmlns:x14=\"\(SparklineParts.nsX14)\" xmlns:xm=\"\(SparklineParts.nsXM)\" xmlns:x=\"\(XMLWriter.nsMain)\" xmlns:r=\"\(XMLWriter.nsRel)\""
              + " xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:xr2=\"http://schemas.microsoft.com/office/spreadsheetml/2015/revision2\">"
              + fragment.xml + "</root>").utf8)
    }
}
