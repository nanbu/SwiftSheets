import Foundation
import SheetCore

/// The same SAX pass as the editable drawing reader, retaining source information without copying entire anchors.
final class DrawingInfoCollector {
    private final class ObjectBuilder {
        let element: String
        let depth: Int
        var kind: DrawingInfo.Object.Kind
        var id: String?, name: String?, geometry: String?
        var transform: DrawingTransform?
        var transformDepth: Int?
        var children: [DrawingInfo.Object] = []
        var properties: [DrawingInfo.Property] = []
        var unmodelled: [String] = []
        var bodyAttributes: [String: String] = [:]
        var paragraphs: [DrawingTextBody.Paragraph] = []
        var paragraphAttributes: [String: String] = [:]
        var runs: [DrawingTextBody.Run] = []
        var bodyDepth: Int?, paragraphDepth: Int?, runDepth: Int?, textDepth: Int?
        var runKind = DrawingTextBody.Run.Kind.text
        var runText = ""
        var runAttributes: [String: String] = [:]
        var runFont: Font?
        var latin: String?, eastAsian: String?, complexScript: String?, fieldID: String?, fieldType: String?
        var color: Color?
        init(element: String, depth: Int) {
            self.element = element; self.depth = depth
            kind = switch element {
            case "sp", "cxnSp": .shape
            case "pic": .image
            case "grpSp": .group
            default: .unknown
            }
        }
        func note(_ property: String) { if !unmodelled.contains(property) { unmodelled.append(property) } }
        func finishRun() {
            runs.append(.init(kind: runKind, text: runText, font: runFont, latinTypeface: latin,
                              eastAsianTypeface: eastAsian, complexScriptTypeface: complexScript,
                              attributes: runAttributes, fieldID: fieldID, fieldType: fieldType))
            runDepth = nil; textDepth = nil
        }
        var object: DrawingInfo.Object {
            if let t = transform, t.rotation != nil && t.rotation != 0 || t.isHorizontallyFlipped || t.isVerticallyFlipped {
                note("rotation or reflection")
            }
            if !paragraphs.isEmpty {
                // The editable shape holds one font and one paragraph alignment, with default text-body geometry.
                let defaults = ["wrap": "square", "rtlCol": "0", "anchor": "t", "vert": "horz",
                                "lIns": "91440", "rIns": "91440", "tIns": "45720", "bIns": "45720"]
                if bodyAttributes.contains(where: { defaults[$0.key] != $0.value }) { note("text body properties") }
                let allRuns = paragraphs.flatMap(\.runs).filter { $0.kind != .lineBreak }
                if Set(allRuns.map(\.font)).count > 1 { note("per-run text formatting") }
                if Set(paragraphs.map { $0.attributes["algn"] }).count > 1
                    || paragraphs.contains(where: { $0.attributes.keys.contains(where: { $0 != "algn" }) }) {
                    note("paragraph properties")
                }
                if allRuns.contains(where: { $0.kind == .field || ($0.eastAsianTypeface != nil && $0.eastAsianTypeface != $0.latinTypeface)
                    || ($0.complexScriptTypeface != nil && $0.complexScriptTypeface != $0.latinTypeface) }) {
                    note("text fields or script fonts")
                }
            }
            return .init(kind: kind, sourceElement: element, sourceID: id, name: name, transform: transform,
                         geometry: geometry, textBody: bodyDepth == nil && paragraphs.isEmpty ? nil : .init(attributes: bodyAttributes, paragraphs: paragraphs),
                         children: children, properties: properties, unmodelledProperties: unmodelled)
        }
    }
    private struct Capture {
        let object: ObjectBuilder
        let element: String
        let namespaces: [String: String]
        var descendants: Set<String> = []
        var attributes: [String: String]
    }
    private var path: [String] = []
    private var namespaceScopes: [[String: String]] = []
    private var semanticScopes: [Bool] = []
    var acceptsText: Bool { semanticScopes.last == true }
    private var stack: [ObjectBuilder] = []
    private var capture: Capture?
    private var anchorStart = 0
    private(set) var objects: [DrawingInfo.Object] = []
    private static let anchorNames: Set<String> = ["oneCellAnchor", "twoCellAnchor", "absoluteAnchor"]
    private static let objectNames: Set<String> = ["sp", "cxnSp", "pic", "graphicFrame", "grpSp", "contentPart", "AlternateContent"]
    private static let capturedNames: Set<String> = ["custGeom", "avLst", "effectLst", "effectDag", "gradFill", "pattFill", "blipFill", "solidFill", "lstStyle", "defRPr", "endParaRPr", "bodyPr", "pPr", "extLst"]
    private static let spreadsheetNamespaces: Set<String> = [DrawingParts.nsSpreadsheetDrawing, "http://purl.oclc.org/ooxml/drawingml/spreadsheetDrawing"]
    private static let mainNamespaces: Set<String> = [DrawingParts.nsDrawingMain, "http://purl.oclc.org/ooxml/drawingml/main"]
    private static let spreadsheetNames: Set<String> = ["wsDr", "oneCellAnchor", "twoCellAnchor", "absoluteAnchor", "from", "to", "col", "colOff", "row", "rowOff", "pos", "sp", "cxnSp", "pic", "graphicFrame", "grpSp", "contentPart", "cNvPr", "cNvSpPr", "cNvPicPr", "nvSpPr", "nvPicPr", "nvGrpSpPr", "nvGraphicFramePr", "cNvGraphicFramePr", "spPr", "grpSpPr", "txBody", "style", "blipFill", "clientData"]

    func start(_ name: String, _ a: [String: String], qualifiedName: String, beginCapture: () -> Void, nestingExceeded: () -> Void) -> Bool {
        guard path.count < 256 else { nestingExceeded(); return false }
        let parent = path.last
        path.append(name)
        var namespaces = namespaceScopes.last ?? [:]
        for (key, value) in a where key == "xmlns" || key.hasPrefix("xmlns:") {
            namespaces[key == "xmlns" ? "" : String(key.dropFirst(6))] = value
        }
        namespaceScopes.append(namespaces)
        let prefix = qualifiedName.firstIndex(of: ":").map { String(qualifiedName[..<$0]) } ?? ""
        let uri = namespaces[prefix] ?? ""
        let namespaceMatches: Bool
        if name == "AlternateContent" { namespaceMatches = uri == "http://schemas.openxmlformats.org/markup-compatibility/2006" }
        else if name == "xfrm" || name == "ext" { namespaceMatches = Self.mainNamespaces.contains(uri) || Self.spreadsheetNamespaces.contains(uri) }
        else if name == "chart" { namespaceMatches = uri == ChartParts.nsChart || uri == "http://purl.oclc.org/ooxml/drawingml/chart" }
        else { namespaceMatches = Self.spreadsheetNames.contains(name) ? Self.spreadsheetNamespaces.contains(uri) : Self.mainNamespaces.contains(uri) }
        let opaqueCapture = capture.map { $0.element != "solidFill" && $0.element != "blipFill" } ?? false
        let semantic = namespaceMatches && (semanticScopes.last ?? true) && !opaqueCapture
        semanticScopes.append(semantic)
        if capture != nil { capture?.descendants.insert(name) }
        guard semantic else { return false }
        if Self.anchorNames.contains(name) { anchorStart = objects.count }
        if let parent, Self.objectNames.contains(name), Self.anchorNames.contains(parent) || parent == "grpSp" {
            // Hashing, equality and destruction walk the recursive public value tree. Bound its depth before
            // constructing it; the drawing reader's normal failure path still preserves the original part.
            guard stack.count < 128 else { nestingExceeded(); return false }
            stack.append(ObjectBuilder(element: name, depth: path.count))
        }
        guard let b = stack.last else { return true }
        if capture == nil, Self.capturedNames.contains(name) || (name == "prstGeom" && !Shape.Geometry(rawValue: a["prst"] ?? "").isPreset) {
            capture = Capture(object: b, element: name, namespaces: namespaces, attributes: a)
            beginCapture()
        }
        switch name {
        case "cNvPr": if b.id == nil { b.id = a["id"]; b.name = a["name"] }
        case "prstGeom" where parent == "spPr" && path.count == b.depth + 2: b.geometry = a["prst"]; if let g = b.geometry, !Shape.Geometry(rawValue: g).isPreset { b.note("geometry (\(g))") }
        case "custGeom" where parent == "spPr" && path.count == b.depth + 2: b.geometry = "custom"; b.note("custom geometry")
        case "graphicData": if a["uri"]?.hasSuffix("/chart") == true { b.kind = .chart }
        case "xfrm" where ((parent == "spPr" || parent == "grpSpPr") && path.count == b.depth + 2) || (parent == "graphicFrame" && path.count == b.depth + 1):
            b.transform = DrawingTransform(); b.transformDepth = path.count
            b.transform?.rotation = a["rot"].flatMap(Int64.init).map { Double($0) / 60_000 }
            b.transform?.isHorizontallyFlipped = a["flipH"] == "1" || a["flipH"] == "true"
            b.transform?.isVerticallyFlipped = a["flipV"] == "1" || a["flipV"] == "true"
        case "off", "chOff":
            guard b.transformDepth != nil && parent == "xfrm" else { break }
            if let x = a["x"].flatMap(Int64.init), let y = a["y"].flatMap(Int64.init) {
                if name == "off" { b.transform?.offset = .init(x: x, y: y) } else { b.transform?.childOffset = .init(x: x, y: y) }
            }
        case "ext", "chExt":
            guard b.transformDepth != nil && parent == "xfrm" else { break }
            if let w = a["cx"].flatMap(Int64.init), let h = a["cy"].flatMap(Int64.init) {
                if name == "ext" { b.transform?.extent = .init(width: w, height: h) } else { b.transform?.childExtent = .init(width: w, height: h) }
            }
        case "txBody" where path.count == b.depth + 1: b.bodyDepth = path.count
        case "bodyPr" where b.bodyDepth != nil: b.bodyAttributes = a
        case "p" where b.bodyDepth != nil:
            b.paragraphDepth = path.count; b.paragraphAttributes = [:]; b.runs = []
        case "pPr" where b.paragraphDepth != nil: b.paragraphAttributes = a
        case "r", "fld", "br":
            guard b.paragraphDepth != nil else { break }
            b.runDepth = path.count; b.runKind = name == "br" ? .lineBreak : (name == "fld" ? .field : .text)
            b.runText = name == "br" ? "\n" : ""; b.runFont = nil; b.runAttributes = [:]
            b.latin = nil; b.eastAsian = nil; b.complexScript = nil; b.fieldID = a["id"]; b.fieldType = a["type"]
        case "rPr" where b.runDepth != nil:
            b.runAttributes = a
            var f = Font()
            f.size = a["sz"].flatMap(Double.init).map { $0 / 100 }
            f.bold = a["b"] == "1" || a["b"] == "true"; f.italic = a["i"] == "1" || a["i"] == "true"
            if let u = a["u"], u != "none" { f.underline = u == "dbl" ? .double : .single }
            b.runFont = f
            let expressed: Set<String> = ["lang", "altLang", "sz", "b", "i", "u", "dirty", "smtClean"]
            if a.contains(where: { !expressed.contains($0.key) && !($0.key == "strike" && $0.value == "noStrike") }) { b.note("run properties") }
        case "latin", "ea", "cs":
            guard b.runDepth != nil else { break }
            if name == "latin" { b.latin = a["typeface"]; b.runFont?.name = a["typeface"] }
            else if name == "ea" { b.eastAsian = a["typeface"] } else { b.complexScript = a["typeface"] }
        case "srgbClr" where b.runDepth != nil:
            b.runFont?.color = a["val"].map { Color(hex: $0) }
        case "schemeClr" where b.runDepth != nil:
            if let v = a["val"], let i = ShapeCollector.themeIndex(v) { b.runFont?.color = .theme(i) }
        case "t" where b.runDepth != nil: b.textDepth = path.count
        default: break
        }
        return true
    }
    func text(_ text: String) {
        guard acceptsText, let b = stack.last, b.textDepth != nil else { return }
        b.runText += text
    }
    @discardableResult func end(_ name: String) -> Bool {
        let semantic = semanticScopes.last == true
        if let b = stack.last, semantic {
            if b.textDepth == path.count { b.textDepth = nil }
            if b.runDepth == path.count { b.finishRun() }
            if b.paragraphDepth == path.count {
                b.paragraphs.append(.init(runs: b.runs, attributes: b.paragraphAttributes)); b.paragraphDepth = nil
            }
            if b.transformDepth == path.count { b.transformDepth = nil }
            if b.depth == path.count {
                let object = b.object
                stack.removeLast()
                if let parent = stack.last { parent.children.append(object) } else { objects.append(object) }
            }
        }
        path.removeLast(); namespaceScopes.removeLast(); semanticScopes.removeLast()
        return semantic
    }
    func captured(_ fragment: XMLFragment) {
        guard let c = capture else { return }
        capture = nil
        let significant: Bool
        switch c.element {
        case "avLst": significant = c.descendants.contains("gd")
        case "effectLst", "effectDag", "lstStyle", "bodyPr", "pPr": significant = !c.descendants.isEmpty
        case "defRPr", "endParaRPr": significant = !c.descendants.isEmpty || c.attributes.keys.contains { $0 != "lang" && $0 != "dirty" }
        case "solidFill": significant = !c.descendants.subtracting(["srgbClr", "schemeClr", "prstClr", "sysClr"]).isEmpty
        case "blipFill": significant = c.descendants.contains("srcRect") || c.descendants.contains("tile")
        default: significant = true
        }
        guard significant else { return }
        c.object.properties.append(.init(name: c.element, xml: fragment.xml, namespaces: c.namespaces))
        c.object.note(c.element)
    }
    func finishAnchor(_ anchor: DrawingAnchor?) {
        for i in anchorStart..<objects.count { objects[i].anchor = anchor }
    }
}
