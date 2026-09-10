import Foundation
import SheetCore

/// Sparklines in the worksheet's extension list (spec Appendix B.79): `<ext uri="{05C60535-…}"><x14:sparklineGroups>`.
/// The reader takes them out of the preserved `extLst` fragment into `Sheet.sparklines`; the writer puts the
/// fragment back untouched while the model still equals what was read, and otherwise regenerates the extension
/// and splices it into whatever else the fragment held.
enum SparklineParts {
    static let uri = "{05C60535-1F16-4fd2-B633-F4F36F0B64E0}"
    static let nsX14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"
    static let nsXM = "http://schemas.microsoft.com/office/excel/2006/main"

    /// Whether a preserved `extLst` fragment carries sparklines.
    static func holdsSparklines(_ fragment: XMLFragment) -> Bool {
        fragment.element == "extLst" && fragment.xml.contains("sparklineGroups")
    }

    /// The groups of an `extLst` fragment. The fragment is parsed inside a root that declares the prefixes the
    /// worksheet root declared, so an undeclared `x14:` cannot trip the parser.
    static func groups(in fragment: XMLFragment, sheetName: String) -> [SparklineGroup] {
        let parser = SparklineParser()
        guard (try? parser.run(ExtensionList.wrapped(fragment), part: "extLst")) != nil else { return [] }
        return parser.groups
    }

    /// The fragment without its sparkline extension; nil when nothing else was in it.
    static func removingSparklines(from fragment: XMLFragment) -> XMLFragment? { ExtensionList.removing(uri: uri, from: fragment) }

    /// The extension for the model's groups, self-contained (its namespaces declared on itself).
    static func extensionXML(_ groups: [SparklineGroup], sheetName: String) -> String {
        var s = "<ext xmlns:x14=\"\(nsX14)\" uri=\"\(uri)\"><x14:sparklineGroups xmlns:xm=\"\(nsXM)\">"
        for g in groups {
            s += "<x14:sparklineGroup"
            if g.kind != .line { s += " type=\"\(XML.esc(g.kind.rawValue))\"" }
            if let w = g.lineWidth, w != 0.75 { s += " lineWeight=\"\(XML.num(w))\"" }
            if g.emptyCells != .zero { s += " displayEmptyCellsAs=\"\(g.emptyCells.rawValue)\"" }
            for (flag, name) in [(g.showsMarkers, "markers"), (g.showsHighPoint, "high"), (g.showsLowPoint, "low"), (g.showsFirstPoint, "first"),
                                 (g.showsLastPoint, "last"), (g.showsNegativePoints, "negative"), (g.showsAxis, "displayXAxis")] where flag {
                s += " \(name)=\"1\""
            }
            s += ">"
            for (color, tag) in [(g.color, "colorSeries"), (g.negativeColor, "colorNegative"), (g.axisColor, "colorAxis"), (g.markersColor, "colorMarkers"),
                                 (g.firstColor, "colorFirst"), (g.lastColor, "colorLast"), (g.highColor, "colorHigh"), (g.lowColor, "colorLow")] {
                if let color { s += StyleRegistry.colorXML("x14:" + tag, color) }
            }
            s += "<x14:sparklines>"
            for line in g.sparklines {
                s += "<x14:sparkline><xm:f>\(XML.esc(qualified(line.dataRange, sheet: sheetName)))</xm:f><xm:sqref>\(line.location.address)</xm:sqref></x14:sparkline>"
            }
            s += "</x14:sparklines></x14:sparklineGroup>"
        }
        return s + "</x14:sparklineGroups></ext>"
    }

    /// `B2:M2` → `'Sheet'!B2:M2` (Excel writes the sheet always); a range that names its sheet stays.
    static func qualified(_ range: String, sheet: String) -> String {
        range.contains("!") ? range : CellRef.formulaSheetName(sheet) + "!" + range
    }

    /// The extension spliced into a preserved `extLst`, or a fresh `extLst` around it.
    static func extLstXML(_ ext: String, into fragment: XMLFragment?) -> String { ExtensionList.splicing([ext], into: fragment).xml }
}

/// `x14:sparklineGroups` → groups. Element names arrive without prefixes.
final class SparklineParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    private(set) var groups: [SparklineGroup] = []
    private var group: SparklineGroup?
    private var inGroups = false
    private var formula: String?, sqref: String?
    private var field: String?
    private var buffer = ""

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "sparklineGroups": inGroups = true
        case "sparklineGroup" where inGroups:
            var g = SparklineGroup(a["type"].map { SparklineGroup.Kind(rawValue: $0) } ?? .line)
            g.lineWidth = a["lineWeight"].flatMap { Double($0) }
            g.emptyCells = a["displayEmptyCellsAs"].flatMap { SparklineGroup.EmptyCells(rawValue: $0) } ?? .zero
            g.showsMarkers = XMLBool.isTrue(a["markers"]); g.showsHighPoint = XMLBool.isTrue(a["high"]); g.showsLowPoint = XMLBool.isTrue(a["low"])
            g.showsFirstPoint = XMLBool.isTrue(a["first"]); g.showsLastPoint = XMLBool.isTrue(a["last"])
            g.showsNegativePoints = XMLBool.isTrue(a["negative"]); g.showsAxis = XMLBool.isTrue(a["displayXAxis"])
            group = g
        case "colorSeries": group?.color = StylesParser.color(a)
        case "colorNegative": group?.negativeColor = StylesParser.color(a)
        case "colorAxis": group?.axisColor = StylesParser.color(a)
        case "colorMarkers": group?.markersColor = StylesParser.color(a)
        case "colorFirst": group?.firstColor = StylesParser.color(a)
        case "colorLast": group?.lastColor = StylesParser.color(a)
        case "colorHigh": group?.highColor = StylesParser.color(a)
        case "colorLow": group?.lowColor = StylesParser.color(a)
        case "sparkline": formula = nil; sqref = nil
        case "f", "sqref": if group != nil { field = name; buffer = "" }
        default: break
        }
    }
    func text(_ s: String) { if field != nil { buffer += s } }
    func end(_ name: String) {
        switch name {
        case "f" where field == "f": formula = buffer; field = nil
        case "sqref" where field == "sqref": sqref = buffer; field = nil
        case "sparkline":
            if let formula, let ref = sqref.flatMap({ CellRef($0.trimmingCharacters(in: .whitespaces)) }) {
                group?.sparklines.append(SparklineGroup.Sparkline(dataRange: formula, location: ref))
            }
        case "sparklineGroup": if let group { groups.append(group) }; group = nil
        case "sparklineGroups": inGroups = false
        default: break
        }
    }
}
