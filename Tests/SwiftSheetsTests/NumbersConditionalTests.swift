import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// Numbers' conditional formats (spec Appendix B.18). The fixture is a document **Numbers 15.3.1 itself produced**:
/// a workbook of one rule kind per column was written as `.xlsx`, imported by Numbers and saved back, which is the
/// only way to see the `predicate_type` integers Apple left unnamed in the Protobuf. Each rule carries a parameter
/// no other rule uses, so the mapping rests on the parameters and not on the order the rules came out in.
@Suite struct NumbersConditionalTests {
    static func fixture() throws -> Workbook {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers/conditional-formats-15.numbers")
        let result = try NumbersCodec.read(try Data(contentsOf: url))
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        return result.workbook
    }

    @Test func readsEveryRuleKindNumbersKeeps() throws {
        let sheet = try Self.fixture().sheets[0]
        var byRange: [String: ConditionalFormattingRule] = [:]
        for block in sheet.conditionalFormatting {
            for rule in block.rules { byRange["\(block.ranges)"] = rule }
        }
        #expect(byRange.count == 5, "\(byRange.keys.sorted())")

        let gt = byRange["A1:A5"]
        #expect(gt?.kind == .cellIs && gt?.operator == .greaterThan && gt?.formulas == ["11"])
        let between = byRange["B1:B5"]
        #expect(between?.kind == .cellIs && between?.operator == .between && between?.formulas == ["13", "14"])
        let ne = byRange["C1:C5"]
        #expect(ne?.kind == .cellIs && ne?.operator == .notEqual && ne?.formulas == ["18"])
        let contains = byRange["D1:D5"]
        #expect(contains?.kind == .containsText && contains?.operator == .containsText && contains?.text == "pp")
        let ends = byRange["E1:E5"]
        #expect(ends?.kind == .endsWith && ends?.operator == .endsWith && ends?.text == "ss")
    }

    /// What the rule paints comes out of the two style archives it names, as a differential style — nil meaning
    /// "leave the cell as it is", so a rule that only fills does not also claim to set the font.
    @Test func readsWhatARulePaints() throws {
        let sheet = try Self.fixture().sheets[0]
        let rules = sheet.conditionalFormatting.flatMap(\.rules)
        for rule in rules {
            #expect(rule.style?.fill == .solid(Color(hex: "FFC7CE")), "\(rule.kind): \(String(describing: rule.style?.fill))")
        }
        // openpyxl gave the two text rules a font colour as well as a fill; the comparisons got only the fill
        let text = rules.filter { [.containsText, .endsWith].contains($0.kind) }
        #expect(text.count == 2)
        #expect(text.allSatisfy { $0.style?.font?.color == Color(hex: "9C0006") })
        let comparisons = rules.filter { $0.kind == .cellIs }
        #expect(comparisons.allSatisfy { $0.style?.font == nil })
    }

    /// The whole point of the mapping: it is a table of observations, and both directions have to agree.
    @Test func theMappingIsOneToOneInBothDirections() {
        for (value, rule) in NumbersConditional.predicates {
            #expect(NumbersConditional.predicateTypes[rule.kind]?[rule.op] == value, "\(rule.kind) \(String(describing: rule.op))")
        }
        #expect(NumbersConditional.predicates.count == 14, "fourteen kinds survived the import")
    }

    /// Numbers records a rule on every cell it covers; the model would rather say the rectangle once.
    @Test func cellsBecomeRectangles() {
        let column = (0..<8).map { CellRef(row: $0, col: 2) }
        #expect("\(NumbersReader.condense(column))" == "C1:C8")
        let block = (0..<3).flatMap { r in (0..<2).map { CellRef(row: r, col: $0) } }
        #expect("\(NumbersReader.condense(block))" == "A1:B3")
        let split = [CellRef(row: 0, col: 0), CellRef(row: 1, col: 0), CellRef(row: 5, col: 0)]
        #expect(NumbersReader.condense(split).ranges.count == 2)
    }

    // MARK: - Writing

    static func workbookWithRules() -> Workbook {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        for r in 0..<5 { sheet[CellRef(row: r, col: 0)] = .integer(r * 7) }
        for r in 0..<5 { sheet[CellRef(row: r, col: 1)] = .text(["pp", "x", "app", "y", "z"][r]) }
        let red = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"), text: Color(hex: "9C0006"))
        sheet.addConditionalFormatting(.cellIs(.greaterThan, "11", paint: red, priority: 1), over: "A1:A5")
        sheet.addConditionalFormatting(.cellIs(between: "3", and: "9", paint: red, priority: 2), over: "A1:A5")
        sheet.addConditionalFormatting(.contains("pp", paint: red, anchoredAt: "B1", priority: 3), over: "B1:B5")
        sheet.addConditionalFormatting(.duplicates(paint: red, priority: 4), over: "B1:B5")
        wb.sheets[0] = sheet
        return wb
    }

    @Test func writesTheRulesNumbersHas() throws {
        let result = try Self.workbookWithRules().write(as: .numbers)
        #expect(!result.warnings.contains { $0.subject == .formatting }, "\(result.warnings.map(\.message))")
        let back = try NumbersCodec.read(result.data)
        #expect(back.warnings.isEmpty, "\(back.warnings.map(\.message))")
        var byRange: [String: [ConditionalFormattingRule]] = [:]
        for block in back.workbook.sheets[0].conditionalFormatting {
            byRange["\(block.ranges)", default: []].append(contentsOf: block.rules)
        }
        let a = byRange["A1:A5"] ?? []
        #expect(a.count == 2, "\(byRange.mapValues { $0.map(\.kind) })")
        #expect(a.contains { $0.operator == .greaterThan && $0.formulas == ["11"] })
        #expect(a.contains { $0.operator == .between && $0.formulas == ["3", "9"] })
        let b = byRange["B1:B5"] ?? []
        #expect(b.contains { $0.kind == .containsText && $0.text == "pp" })
        #expect(b.contains { $0.kind == .duplicateValues })
        #expect(b.allSatisfy { $0.style?.fill == .solid(Color(hex: "FFC7CE")) })
    }

    /// The eleven kinds Numbers drops when *it* imports an Excel file are the eleven this refuses to invent.
    @Test func saysWhichKindsNumbersHasNoWordFor() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet["A1"] = 1
        let red = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"))
        sheet.addConditionalFormatting(.colorScale(.twoColor(from: .white, to: Color(hex: "63BE7B")), priority: 1), over: "A1:A5")
        sheet.addConditionalFormatting(.dataBar(DataBar(color: Color(hex: "638EC6")), priority: 2), over: "A1:A5")
        sheet.addConditionalFormatting(.iconSet(.threeBand(), priority: 3), over: "A1:A5")
        sheet.addConditionalFormatting(.top(3, paint: red, priority: 4), over: "A1:A5")
        sheet.addConditionalFormatting(.aboveAverage(true, paint: red, priority: 5), over: "A1:A5")
        wb.sheets[0] = sheet
        let result = try wb.write(as: .numbers)
        let dropped = result.warnings.filter { $0.message.contains("Numbers has no rule of that kind") }
        #expect(dropped.count == 5, "\(result.warnings.map(\.message))")
        #expect(dropped.contains { $0.message.contains("colorScale") } && dropped.contains { $0.message.contains("dataBar") })
        // and nothing of them is left behind in the document
        let back = try NumbersCodec.read(result.data).workbook.sheets[0]
        #expect(back.conditionalFormatting.isEmpty)
    }

    /// A cell inside a rule's range that holds nothing still has to name the rule, or the highlight stops at the
    /// last cell that happened to have a value.
    @Test func emptyCellsInsideARangeStillCarryTheRule() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet["A1"] = 20
        sheet["A5"] = 30
        sheet.addConditionalFormatting(.cellIs(.greaterThan, "11", paint: .highlight(fill: Color(hex: "FFC7CE")), priority: 1), over: "A1:A5")
        wb.sheets[0] = sheet
        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.conditionalFormatting.first.map { "\($0.ranges)" } == "A1:A5")
    }

    /// Two things Numbers refuses that nothing else notices, both found by asking it (Appendix B.18):
    /// a rule naming only one of its two styles — the schema marks both required — and a rule whose style lives
    /// in a component the list holding it has not declared it uses.
    @Test func everyRuleNamesBothStylesAndDeclaresWhereTheyLive() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 20
        wb.sheets[0].addConditionalFormatting(.cellIs(.greaterThan, "11", paint: .highlight(fill: Color(hex: "FFC7CE")), priority: 1),
                                              over: "A1:A5")
        let doc = try NumbersDocument(data: try wb.write(as: .numbers).data)

        let sets = doc.identifiers(ofType: "TST.ConditionalStyleSetArchive")
        #expect(sets.count == 1)
        let rules = sets.first.flatMap { doc.object($0)?.message("rules")?.messages("rule") } ?? []
        #expect(rules.count == 1)
        let cell = rules.first?.reference("cell_style")
        let text = rules.first?.reference("text_style")
        #expect(cell != nil && text != nil, "a rule that only fills still names a text style")

        // the set has to sit in the same file as the list that names it
        let lists = doc.identifiers(ofType: "TST.TableDataList").filter { id in
            doc.object(id)?.int("listType") == NumbersSchema.shared.enums["TST.TableDataList.ListType"]?["CONDITIONAL_STYLE"]
                && !(doc.object(id)?.messages("entries").isEmpty ?? true)
        }
        #expect(lists.count == 1)
        #expect(doc.locations[lists[0]]?.0 == doc.locations[sets[0]]?.0, "the rule set lives beside its list")

        // and the list's component has to declare that it reaches into the component holding the styles
        guard let listComponent = doc.componentID(forObject: lists[0]),
              let components = doc.object(NumbersDocument.packageID)?.messages("components"),
              let entry = components.first(where: { $0.int("identifier") == listComponent }) else {
            Issue.record("the conditional-style list has no component entry")
            return
        }
        let declared = Set(entry.messages("external_references").compactMap { $0.int("object_identifier") })
        for style in [cell, text].compactMap({ $0 }) where doc.componentID(forObject: style) != listComponent {
            #expect(declared.contains(style), "the list does not declare that it names style \(style)")
        }
    }
}
