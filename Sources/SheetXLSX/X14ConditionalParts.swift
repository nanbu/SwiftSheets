import Foundation
import SheetCore

/// Excel 2010's conditional-format extension (spec Appendix B.82): a rule in `<conditionalFormatting>` names an
/// `x14:id` in its own `extLst`, and the worksheet's `extLst` carries `x14:conditionalFormattings` whose
/// `x14:cfRule` of that id says what the 2007 form cannot — a data bar's negative and axis colours, its axis
/// position, direction, solid fill and border; an icon set's icons chosen one by one. The reader folds those into
/// the model's rules; the writer regenerates the extension beside the rules, with fresh ids.
enum X14ConditionalParts {
    static let ruleURI = "{B025F937-C7B1-47D3-B67F-A62EFF666E3E}"
    static let sheetURI = "{78C0D931-6437-407d-A8EE-F0AAD7539E65}"

    /// What one `x14:cfRule` says about a data bar or an icon set.
    struct Extension {
        var dataBar: DataBar?     // only the extension's own fields are filled in
        var icons: [IconSet.Icon]?
        var custom = false
        var kind: String
    }

    // MARK: - Reading

    /// The extensions of a worksheet `extLst` fragment by rule id, and how many `x14:cfRule` elements the model
    /// could not take (rule kinds the 2007 form does not know, which live in the extension alone).
    static func extensions(in fragment: XMLFragment) -> (byID: [String: Extension], unmodelled: Int) {
        let parser = X14ConditionalParser()
        guard (try? parser.run(ExtensionList.wrapped(fragment), part: "extLst")) != nil else { return ([:], 0) }
        return (parser.byID, parser.unmodelled)
    }

    /// The extension folded into the rule it belongs to.
    static func apply(_ ext: Extension, to rule: inout ConditionalFormattingRule) {
        if var bar = rule.dataBar, let x = ext.dataBar {
            bar.negativeColor = x.negativeColor; bar.axisColor = x.axisColor; bar.axisPosition = x.axisPosition
            bar.direction = x.direction; bar.gradient = x.gradient; bar.borderColor = x.borderColor
            rule.dataBar = bar
        }
        if var set = rule.iconSet, let icons = ext.icons, ext.custom { set.customIcons = icons; rule.iconSet = set }
    }

    // MARK: - Writing

    /// Whether a rule needs the extension at all.
    static func needsExtension(_ rule: ConditionalFormattingRule) -> Bool {
        rule.dataBar?.usesExtension == true || rule.iconSet?.customIcons != nil
    }

    /// The `extLst` inside a `<cfRule>`, naming the extension's id.
    static func ruleReferenceXML(id: String) -> String {
        "<extLst><ext xmlns:x14=\"\(SparklineParts.nsX14)\" uri=\"\(ruleURI)\"><x14:id>\(id)</x14:id></ext></extLst>"
    }

    /// One `x14:cfRule` for a rule that needs the extension.
    static func ruleXML(_ rule: ConditionalFormattingRule, id: String) -> String {
        var s = "<x14:cfRule type=\"\(rule.kind.rawValue)\" id=\"\(id)\">"
        if let bar = rule.dataBar {
            s += "<x14:dataBar"
            if let v = bar.minLength { s += " minLength=\"\(v)\"" }
            if let v = bar.maxLength { s += " maxLength=\"\(v)\"" }
            if let p = bar.axisPosition { s += " axisPosition=\"\(p.rawValue)\"" }
            if let d = bar.direction { s += " direction=\"\(d.rawValue)\"" }
            if !bar.gradient { s += " gradient=\"0\"" }
            if bar.borderColor != nil { s += " border=\"1\"" }
            if bar.negativeColor != nil { s += " negativeBarColorSameAsPositive=\"0\"" }
            s += ">" + valueXML(bar.minimum) + valueXML(bar.maximum)
            if let c = bar.borderColor { s += StyleRegistry.colorXML("x14:borderColor", c) }
            if let c = bar.negativeColor { s += StyleRegistry.colorXML("x14:negativeFillColor", c) }
            if let c = bar.axisColor { s += StyleRegistry.colorXML("x14:axisColor", c) }
            s += "</x14:dataBar>"
        }
        if let set = rule.iconSet, let icons = set.customIcons {
            s += "<x14:iconSet iconSet=\"\(XML.esc(set.name))\" custom=\"1\"\(set.showsValue ? "" : " showValue=\"0\"")\(set.percent ? "" : " percent=\"0\"")\(XML.attr("reverse", set.reverse))>"
            s += set.values.map { valueXML($0, includeGTE: true) }.joined()
            for (i, icon) in icons.enumerated() { s += "<x14:cfIcon iconSet=\"\(XML.esc(icon.setName))\" iconId=\"\(icon.index)\"/>"; _ = i }
            s += "</x14:iconSet>"
        }
        return s + "</x14:cfRule>"
    }

    /// The x14 form of a boundary: `min` / `max` are `autoMin` / `autoMax`, a value is an `xm:f` child.
    static func valueXML(_ v: ConditionalValue, includeGTE: Bool = false) -> String {
        let type: String
        switch v.kind { case .min: type = "autoMin"; case .max: type = "autoMax"; default: type = v.kind.rawValue }
        var s = "<x14:cfvo type=\"\(type)\""
        if includeGTE, !v.greaterThanOrEqual { s += " gte=\"0\"" }
        if let value = v.value, v.kind != .min, v.kind != .max { return s + "><xm:f>\(XML.esc(value))</xm:f></x14:cfvo>" }
        return s + "/>"
    }

    /// The worksheet extension around the blocks: (sqref, the x14:cfRule elements of that block).
    static func sheetExtensionXML(_ blocks: [(sqref: String, rules: String)]) -> String {
        var s = "<ext xmlns:x14=\"\(SparklineParts.nsX14)\" uri=\"\(sheetURI)\"><x14:conditionalFormattings>"
        for b in blocks {
            s += "<x14:conditionalFormatting xmlns:xm=\"\(SparklineParts.nsXM)\">" + b.rules + "<xm:sqref>\(XML.esc(b.sqref))</xm:sqref></x14:conditionalFormatting>"
        }
        return s + "</x14:conditionalFormattings></ext>"
    }

    static func freshID() -> String { "{" + UUID().uuidString + "}" }
}

/// `x14:conditionalFormattings` → extensions by rule id. Element names arrive without prefixes.
final class X14ConditionalParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    private(set) var byID: [String: X14ConditionalParts.Extension] = [:]
    private(set) var unmodelled = 0
    private var inFormattings = false
    private var current: X14ConditionalParts.Extension?
    private var currentID: String?
    private var inIconSet = false

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "conditionalFormattings": inFormattings = true
        case "cfRule" where inFormattings:
            let kind = a["type"] ?? ""
            current = X14ConditionalParts.Extension(kind: kind)
            currentID = a["id"]
            if kind != "dataBar" && kind != "iconSet" { unmodelled += 1 }
        case "dataBar" where current != nil:
            var bar = DataBar(color: .black)
            bar.axisPosition = a["axisPosition"].flatMap { DataBar.AxisPosition(rawValue: $0) }
            bar.direction = a["direction"].flatMap { DataBar.Direction(rawValue: $0) }
            bar.gradient = XMLBool.isNotFalse(a["gradient"])
            current?.dataBar = bar
        case "negativeFillColor" where current != nil: current?.dataBar?.negativeColor = StylesParser.color(a)
        case "axisColor" where current != nil: current?.dataBar?.axisColor = StylesParser.color(a)
        case "borderColor" where current != nil: current?.dataBar?.borderColor = StylesParser.color(a)
        case "iconSet" where current != nil:
            inIconSet = true
            current?.custom = XMLBool.isTrue(a["custom"])
            current?.icons = []
        case "cfIcon" where inIconSet:
            if let set = a["iconSet"], let id = Int(a["iconId"] ?? "") { current?.icons?.append(IconSet.Icon(setName: set, index: id)) }
        default: break
        }
    }
    func text(_ s: String) {}
    func end(_ name: String) {
        switch name {
        case "iconSet": inIconSet = false
        case "cfRule" where current != nil:
            if let id = currentID, let c = current, c.kind == "dataBar" || c.kind == "iconSet" { byID[id] = c }
            current = nil; currentID = nil
        case "conditionalFormattings": inFormattings = false
        default: break
        }
    }
}
