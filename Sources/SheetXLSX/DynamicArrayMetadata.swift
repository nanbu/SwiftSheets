import Foundation
import SheetCore

/// Reads only the links needed to identify spill origins. All source bytes and unknown records stay opaque.
enum DynamicArrayMetadata {
    static let relationshipType = "/sheetMetadata"
    static let contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheetMetadata+xml"
    static let namespace = "http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray"
    static let extensionURI = "{BDBB8CDC-FA1E-496E-A857-3C3F30C029C3}"

    struct Indices: Sendable {
        var dynamic: Set<Int> = []
        var pure: Set<Int> = []
        var resolved: Set<Int> = []
    }

    static func read(_ data: Data, part: String) throws -> Indices {
        let parser = MetadataParser(part: part)
        try parser.run(data, part: part)
        return parser.indices
    }

    private final class MetadataParser: SAXHandler {
        var driver: SAXDriver?
        var rootAttributes: [String: String] = [:]
        private let part: String
        init(part: String) { self.part = part }
        struct Record { var type: Int; var value: Int }
        struct Block { var records: [Record] = []; var pure = true }
        struct FutureBlock { var dynamic = false; var pure = true; var recognized = false; var propertiesCount = 0 }
        private var stack: [String] = []
        private var namespaceStack: [[String: String]] = []
        private var types: [String] = []
        private var future: [String: [FutureBlock]] = [:]
        private var futureName: String?
        private var futureBlocks: [FutureBlock] = []
        private var futureBlock: FutureBlock?
        private var extensionIsDynamic = false
        private var blocks: [Block] = []
        private var cellBlock: Block?

        var indices: Indices {
            var result = Indices()
            for (index, block) in blocks.enumerated() {
                for record in block.records where record.type > 0 && types.indices.contains(record.type - 1) {
                    let name = types[record.type - 1]
                    guard name == "XLDAPR", let values = future[name], values.indices.contains(record.value), values[record.value].recognized else { continue }
                    result.resolved.insert(index + 1)
                    guard values[record.value].dynamic else { continue }
                    result.dynamic.insert(index + 1)
                    if block.pure && block.records.count == 1 && values[record.value].pure { result.pure.insert(index + 1) }
                }
            }
            return result
        }

        func start(_ name: String, _ attributes: [String: String]) {
            guard stack.count < 256 else {
                fail(.malformedPart(path: part, detail: "cell metadata nesting exceeds 256 elements"))
                return
            }
            var namespaces = namespaceStack.last ?? [:]
            for (key, value) in attributes {
                if key == "xmlns" { namespaces[""] = value }
                else if key.hasPrefix("xmlns:") { namespaces[String(key.dropFirst(6))] = value }
            }
            namespaceStack.append(namespaces)
            let qualified = driver?.qualifiedName ?? name
            let prefix = qualified.firstIndex(of: ":").map { String(qualified[..<$0]) } ?? ""
            let namespaceURI = namespaces[prefix]
            let a = attributes.filter { $0.key != "xmlns" && !$0.key.hasPrefix("xmlns:") }
            let parent = stack.last
            let main = namespaceURI == XMLWriter.nsMain
            stack.append(main ? name : "?")
            guard stack.first == "metadata" else { return }
            if main, name == "metadataType", parent == "metadataTypes", stack.count == 3 { types.append(a["name"] ?? "") }
            if main, name == "futureMetadata", parent == "metadata", stack.count == 2 { futureName = a["name"]; futureBlocks = [] }
            if main, name == "bk", parent == "futureMetadata", stack.count == 3 { futureBlock = FutureBlock(pure: a.isEmpty) }
            else if futureBlock != nil {
                if main, name == "extLst", parent == "bk", stack.count == 4 { }
                else if main, name == "ext", parent == "extLst", stack.count == 5 {
                    extensionIsDynamic = a["uri"]?.uppercased() == DynamicArrayMetadata.extensionURI
                    if !extensionIsDynamic || !a.keys.allSatisfy({ $0 == "uri" }) { futureBlock?.pure = false }
                } else if name == "dynamicArrayProperties", namespaceURI == DynamicArrayMetadata.namespace,
                          parent == "ext", stack.count == 6, extensionIsDynamic {
                    let count = (futureBlock?.propertiesCount ?? 0) + 1
                    futureBlock?.propertiesCount = count
                    let flag = a["fDynamic"]
                    futureBlock?.recognized = count == 1 && (flag == nil || ["0", "1", "true", "false"].contains(flag!))
                    futureBlock?.dynamic = XMLBool.isTrue(a["fDynamic"])
                    if !a.keys.allSatisfy({ $0 == "fDynamic" || $0 == "fCollapsed" })
                        || a["fCollapsed"].map({ !["0", "false"].contains($0) }) == true { futureBlock?.pure = false }
                } else { futureBlock?.pure = false }
            }
            if main, name == "bk", parent == "cellMetadata", stack.count == 3 { cellBlock = Block(pure: a.isEmpty) }
            else if cellBlock != nil {
                if main, name == "rc", parent == "bk", stack.count == 4,
                   let type = a["t"].flatMap(Int.init), let value = a["v"].flatMap(Int.init), value >= 0 {
                    cellBlock?.records.append(Record(type: type, value: value))
                    if !a.keys.allSatisfy({ $0 == "t" || $0 == "v" }) { cellBlock?.pure = false }
                } else { cellBlock?.pure = false }
            }
        }

        func end(_ name: String) {
            let parent = stack.dropLast().last
            if stack.last != "?" {
                if name == "bk", parent == "futureMetadata", stack.count == 3, let block = futureBlock { futureBlocks.append(block); futureBlock = nil }
                if name == "futureMetadata", stack.count == 2, let futureName { future[futureName] = futureBlocks; self.futureName = nil }
                if name == "bk", parent == "cellMetadata", stack.count == 3, let block = cellBlock { blocks.append(block); cellBlock = nil }
                if name == "ext" { extensionIsDynamic = false }
            }
            if !stack.isEmpty { stack.removeLast() }
            if !namespaceStack.isEmpty { namespaceStack.removeLast() }
        }
    }

    /// Every dynamic origin may share this block: its properties carry no origin-specific values.
    static var xml: String {
        XMLWriter.header + "<metadata xmlns=\"\(XMLWriter.nsMain)\" xmlns:xda=\"\(namespace)\">"
        + "<metadataTypes count=\"1\"><metadataType name=\"XLDAPR\" minSupportedVersion=\"120000\" copy=\"1\" pasteAll=\"1\" pasteValues=\"1\" merge=\"1\" splitFirst=\"1\" rowColShift=\"1\" clearFormats=\"1\" clearComments=\"1\" assign=\"1\" coerce=\"1\" cellMeta=\"1\"/></metadataTypes>"
        + "<futureMetadata name=\"XLDAPR\" count=\"1\"><bk><extLst><ext uri=\"\(extensionURI)\"><xda:dynamicArrayProperties fDynamic=\"1\" fCollapsed=\"0\"/></ext></extLst></bk></futureMetadata>"
        + "<cellMetadata count=\"1\"><bk><rc t=\"1\" v=\"0\"/></bk></cellMetadata></metadata>"
    }

    struct WritePlan {
        var cells: [[CellRef: XLSXCellMetadata]]
        var generatedPath: String?
    }

    /// Reuses source indices without rewriting unknown metadata. A mixed block cannot be split safely.
    static func plan(_ workbook: Workbook, preservesSource: Bool, opaque: [String: OpaquePart]) throws -> WritePlan {
        let source = workbook.preserved
        let hasSource = preservesSource && source.cellMetadataPath.map { opaque[$0] != nil } == true
        var result = WritePlan(cells: [], generatedPath: nil)
        let hasDynamic = workbook.sheets.contains { !$0.table.dynamicArrayOrigins.isEmpty }
        var sharedIndex = hasSource ? source.pureDynamicArrayMetadataIndices.min() : nil
        if hasDynamic && !hasSource {
            var number = 1
            var path = "xl/metadata.xml"
            while opaque[path] != nil { path = "xl/metadata\(number).xml"; number += 1 }
            result.generatedPath = path
            sharedIndex = 1
        }
        for sheet in workbook.sheets {
            let table = sheet.table
            let sameSource = table.xlsxCellMetadataSourceID.matches(source.cellMetadataSourceID)
            if !sameSource {
                // A copied sheet's cm=1 can name something entirely different in this destination workbook.
                // Only origin-independent pure dynamic records can be replaced without their source bytes.
                for (ref, metadata) in table.xlsxCellMetadata {
                    let isPureDynamic = metadata.cell.flatMap(Int.init).map { table.xlsxPureDynamicMetadataIndices.contains($0) } ?? false
                    guard metadata.value == nil && (metadata.cell == nil || isPureDynamic) else {
                        throw SheetError.unsupportedFeature("cannot import cell metadata at \(sheet.name)!\(ref.address): its unknown or value metadata belongs to another workbook")
                    }
                }
            }
            var cells = hasSource && sameSource ? table.xlsxCellMetadata : [:]
            for (ref, original) in cells {
                guard let index = original.cell.flatMap(Int.init), source.dynamicArrayMetadataIndices.contains(index),
                      !table.dynamicArrayOrigins.contains(ref) else { continue }
                guard source.pureDynamicArrayMetadataIndices.contains(index) else {
                    throw SheetError.unsupportedFeature("cannot remove dynamic-array metadata at \(sheet.name)!\(ref.address): its cell metadata block also holds unknown records in \(source.cellMetadataPath ?? "metadata")")
                }
                cells[ref]?.cell = nil
            }
            for origin in table.dynamicArrayOrigins {
                guard let range = table.arrayFormulas[origin], range.topLeft == origin,
                      range.sheet == nil || range.sheet == sheet.name,
                      case .formula? = table.cells[origin]?.value else {
                    throw SheetError.invalidWorkbook("dynamic array origin \(sheet.name)!\(origin.address) must hold a formula at the top-left of its array range")
                }
                if let index = cells[origin]?.cell.flatMap(Int.init), source.dynamicArrayMetadataIndices.contains(index) { continue }
                guard cells[origin]?.cell == nil else {
                    throw SheetError.unsupportedFeature("cannot replace unknown cell metadata at \(sheet.name)!\(origin.address) with dynamic-array metadata")
                }
                guard let sharedIndex else {
                    throw SheetError.unsupportedFeature("cannot add dynamic-array metadata at \(sheet.name)!\(origin.address): the existing metadata part has no reusable pure dynamic-array block")
                }
                var metadata = cells[origin] ?? XLSXCellMetadata()
                metadata.cell = String(sharedIndex)
                cells[origin] = metadata
            }
            result.cells.append(cells)
        }
        return result
    }
}
