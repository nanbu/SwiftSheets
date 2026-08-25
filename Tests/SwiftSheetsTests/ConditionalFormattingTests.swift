import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Cells that repaint themselves according to what they hold (`<conditionalFormatting>`), and the differential
/// formats they paint with (`<dxfs>`).
@Suite struct ConditionalFormattingTests {

    /// The everyday rules: a comparison, a formula, a text match, a rank — written, read back, unchanged.
    // openpyxl: formatting/tests/test_formatting.py::TestConditionalFormatting::test_ctor
    // openpyxl: formatting/tests/test_formatting.py::test_conditional_formatting_read
    // openpyxl: formatting/tests/test_rule.py::TestRule::test_create
    // openpyxl: formatting/tests/test_rule.py::TestRule::test_serialise
    // openpyxl: formatting/tests/test_rule.py::test_cellis_rule
    // openpyxl: formatting/tests/test_rule.py::test_formula_rule
    @Test func theEverydayRulesRoundTrip() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        for r in 0..<10 { ws[r, 0] = .integer(r * 7) }
        let red = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"), text: Color(hex: "9C0006"))
        ws.addConditionalFormatting(.cellIs(.greaterThan, "40", paint: red), over: "A1:A10")
        ws.addConditionalFormatting(.cellIs(between: "10", and: "20", paint: red), over: "A1:A10")
        ws.addConditionalFormatting(.expression("$A1=0", paint: red), over: "A1:A10")
        ws.addConditionalFormatting(.top(3, paint: red, bottom: true, percent: true), over: "A1:A10")
        ws.addConditionalFormatting(.aboveAverage(false, paint: red), over: "A1:A10")
        ws.addConditionalFormatting(.duplicates(paint: red), over: "A1:A10")
        ws.addConditionalFormatting(.contains("済", paint: red), over: "B1:B10")
        wb.sheets[0] = ws

        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(xml.contains("type=\"cellIs\"") && xml.contains("operator=\"greaterThan\""))
        #expect(xml.contains("<formula>40</formula>"))
        #expect(xml.contains("operator=\"between\"") && xml.contains("<formula>10</formula><formula>20</formula>"))
        #expect(xml.contains("type=\"top10\"") && xml.contains("rank=\"3\"") && xml.contains("bottom=\"1\"") && xml.contains("percent=\"1\""))
        #expect(xml.contains("type=\"aboveAverage\"") && xml.contains("aboveAverage=\"0\""))
        #expect(xml.contains("type=\"duplicateValues\""))
        #expect(xml.contains("type=\"containsText\"") && xml.contains("text=\"済\""))
        #expect(xml.contains("SEARCH(&quot;済&quot;,B1)"), "the formula reads the range's own first cell, not A1")

        let again = try Workbook(data: data).sheets[0]
        #expect(!again.hasUnmodelledConditionalFormats)
        #expect(again.conditionalFormatting.flatMap(\.rules).count == 7)
        #expect(again.conditionalFormatting == ws.conditionalFormatting)
    }

    /// The format a rule paints with lands in the workbook's `<dxfs>` table and comes back the same.
    // openpyxl: styles/tests/test_differential.py::test_parse
    // openpyxl: styles/tests/test_differential.py::test_serialise
    // openpyxl: styles/tests/test_differential.py::TestDifferentialStyleList::test_ctor
    @Test func theDifferentialFormatRoundTrips() throws {
        var wb = Workbook()
        var style = DifferentialStyle(font: DifferentialFont(bold: true, italic: false, color: Color(hex: "9C0006")),
                                      fill: .solid(Color(hex: "FFC7CE")),
                                      border: .all(Side(style: .thin, color: Color(hex: "9C0006"))),
                                      numberFormat: "0.00%")
        style.alignment = Alignment(horizontal: .center)
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].addConditionalFormatting(.cellIs(.greaterThan, "0", paint: style), over: "A1:A9")

        let data = try wb.data(as: .xlsx)
        let styles = try Package.part("xl/styles.xml", of: data)
        #expect(styles.contains("<dxfs count=\"1\">"))
        #expect(styles.contains("<b val=\"1\"/><i val=\"0\"/>"), "an explicit \"not italic\" is not the same as silence")
        #expect(styles.contains("formatCode=\"0.00%\""))

        let again = try Workbook(data: data)
        #expect(again.differentialStyles.count == 1)
        #expect(again.sheets[0].conditionalFormatting[0].rules[0].style == style)
    }

    /// Colour scales, data bars and icon sets — the three that paint themselves rather than through a format.
    // openpyxl: formatting/tests/test_rule.py::TestFormatObject::test_create
    // openpyxl: formatting/tests/test_rule.py::TestFormatObject::test_serialise
    // openpyxl: formatting/tests/test_rule.py::TestColorScale::test_create
    // openpyxl: formatting/tests/test_rule.py::TestColorScale::test_serialise
    // openpyxl: formatting/tests/test_rule.py::TestColorScale::test_three_colors
    // openpyxl: formatting/tests/test_rule.py::TestDataBar::test_create
    // openpyxl: formatting/tests/test_rule.py::TestDataBar::test_serialise
    // openpyxl: formatting/tests/test_rule.py::test_databar_rule
    // openpyxl: formatting/tests/test_rule.py::TestIconSet::test_create
    // openpyxl: formatting/tests/test_rule.py::TestIconSet::test_serialise
    // openpyxl: formatting/tests/test_rule.py::test_iconset_rule
    @Test func theSelfPaintingRulesRoundTrip() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = 1
        ws.addConditionalFormatting(.colorScale(.threeColor(from: Color(hex: "F8696B"), through: Color(hex: "FFEB84"),
                                                            to: Color(hex: "63BE7B"))), over: "A1:A9")
        ws.addConditionalFormatting(.dataBar(DataBar(color: Color(hex: "638EC6"), minLength: 10, maxLength: 90)), over: "B1:B9")
        ws.addConditionalFormatting(.iconSet(IconSet(name: "5Rating", values: [.percent(0), .percent(20), .percent(40),
                                                                              .percent(60), .percent(80)], reverse: true)),
                                    over: "C1:C9")
        wb.sheets[0] = ws
        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(xml.contains("<colorScale><cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>"))
        #expect(xml.contains("<dataBar minLength=\"10\" maxLength=\"90\">"))
        #expect(xml.contains("<iconSet iconSet=\"5Rating\" reverse=\"1\">"))

        let again = try Workbook(data: data).sheets[0]
        #expect(again.conditionalFormatting == ws.conditionalFormatting)
        #expect(again.conditionalFormatting[0].rules[0].colorScale?.colors.count == 3)
        #expect(again.conditionalFormatting[1].rules[0].dataBar?.color == Color(hex: "638EC6"))
        #expect(again.conditionalFormatting[2].rules[0].iconSet?.values.count == 5)
    }

    /// Priorities decide which rule wins; they are the sheet's, so the writer renumbers them 1…n in that order.
    @Test func prioritiesAreRenumberedInOrder() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = 1
        let paint = DifferentialStyle.highlight(fill: .white)
        ws.conditionalFormatting = [
            ConditionalFormatting("A1:A9", rules: [.cellIs(.greaterThan, "3", paint: paint, priority: 40)])!,
            ConditionalFormatting("B1:B9", rules: [.cellIs(.lessThan, "1", paint: paint, priority: 7),
                                                  .cellIs(.equal, "2", paint: paint, priority: 90)])!,
        ]
        wb.sheets[0] = ws
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: try wb.data(as: .xlsx))
        #expect(xml.contains("sqref=\"B1:B9\"><cfRule type=\"cellIs\" dxfId=\"0\" priority=\"1\" operator=\"lessThan\""))
        #expect(xml.contains("sqref=\"A1:A9\"><cfRule type=\"cellIs\" dxfId=\"0\" priority=\"2\" operator=\"greaterThan\""))
        #expect(xml.contains("priority=\"3\" operator=\"equal\""))
    }

    /// `stopIfTrue`, the pivot flag and a multi-area sqref survive.
    @Test func blockAttributesSurvive() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var rule = ConditionalFormattingRule.expression("A1>0", paint: .highlight(text: .black))
        rule.stopIfTrue = true
        wb.sheets[0].conditionalFormatting = [ConditionalFormatting("A1:A9 C1:C9", rules: [rule], pivot: true)!]
        let data = try wb.data(as: .xlsx)
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: data).contains("sqref=\"A1:A9 C1:C9\" pivot=\"1\""))
        let again = try Workbook(data: data).sheets[0].conditionalFormatting[0]
        #expect(again.pivot && again.rules[0].stopIfTrue)
        #expect(again.ranges == MultiCellRange("A1:A9 C1:C9"))
    }

    /// A rule kind the model does not know — or one carrying Excel's `<extLst>` extensions — keeps the file's own
    /// block: half a rule would paint the wrong cells.
    @Test func aRuleTheModelCannotSayKeepsTheSourceBlock() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        let plain = try wb.data(as: .xlsx)
        let exotic = try Package.repacking(plain, replacing: "xl/worksheets/sheet1.xml", with: Data(
            try Package.part("xl/worksheets/sheet1.xml", of: plain)
                .replacingOccurrences(of: "<pageMargins",
                                      with: "<conditionalFormatting sqref=\"A1:A9\"><cfRule type=\"dataBar\" priority=\"1\"><dataBar><cfvo type=\"min\"/><cfvo type=\"max\"/><color rgb=\"FF638EC6\"/></dataBar><extLst><ext uri=\"{B025F937}\"/></extLst></cfRule></conditionalFormatting><pageMargins").utf8))
        var again = try Workbook(data: exotic)
        #expect(again.sheets[0].hasUnmodelledConditionalFormats)
        #expect(again.sheets[0].conditionalFormatting.isEmpty, "half a rule is worse than none")
        again.sheets[0].addConditionalFormatting(.cellIs(.equal, "1", paint: .highlight(fill: .white)), over: "ZZ1")
        let result = try again.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("conditional format") })
        let out = try Package.part("xl/worksheets/sheet1.xml", of: result.data)
        #expect(out.contains("{B025F937}") && !out.contains("ZZ1"))
        #expect(out.components(separatedBy: "<conditionalFormatting").count == 2)
    }

    /// A rule read from a file keeps the exact `<dxf>` entry it pointed at — including the parts the model has no
    /// word for — and an edit to it replaces that entry rather than adding a second.
    @Test func anUntouchedRuleKeepsItsSourceFormat() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].addConditionalFormatting(.cellIs(.greaterThan, "0", paint: .highlight(fill: Color(hex: "FFC7CE"))), over: "A1:A9")
        let source = try wb.data(as: .xlsx)

        var again = try Workbook(data: source)
        again.sheets[0]["A2"] = 2                                   // an edit that has nothing to do with the rule
        let untouched = try again.data(as: .xlsx)
        #expect(try Package.part("xl/styles.xml", of: untouched).contains("<dxfs count=\"1\">"))

        again.sheets[0].conditionalFormatting[0].rules[0].style = .highlight(fill: Color(hex: "C6EFCE"))
        let edited = try again.data(as: .xlsx)
        let styles = try Package.part("xl/styles.xml", of: edited)
        #expect(styles.contains("<dxfs count=\"1\">"), "an edit replaces the entry, it does not add one")
        #expect(styles.contains("C6EFCE") && !styles.contains("FFC7CE"))
    }

    /// A file may point two rules at one differential format. Editing one of them must not repaint the other.
    @Test func editingOneOfTwoRulesSharingAFormatLeavesTheOtherAlone() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        let pink = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"))
        wb.sheets[0].addConditionalFormatting(.cellIs(.greaterThan, "1", paint: pink), over: "A1:A9")
        let one = try wb.data(as: .xlsx)
        // a second rule pointing at the same entry — which is what Excel and LibreOffice write when two rules paint alike
        let shared = try Package.repacking(one, replacing: "xl/worksheets/sheet1.xml", with: Data(
            try Package.part("xl/worksheets/sheet1.xml", of: one)
                .replacingOccurrences(of: "<pageMargins", with:
                    "<conditionalFormatting sqref=\"B1:B9\"><cfRule type=\"cellIs\" dxfId=\"0\" priority=\"2\" operator=\"lessThan\"><formula>0</formula></cfRule></conditionalFormatting><pageMargins").utf8))

        var again = try Workbook(data: shared)
        #expect(again.differentialStyles.count == 1)
        #expect(again.sheets[0].conditionalFormatting.count == 2)
        #expect(again.sheets[0].conditionalFormatting[1].rules[0].style == pink)
        again.sheets[0].conditionalFormatting[0].rules[0].style = .highlight(fill: Color(hex: "C6EFCE"))

        let out = try again.data(as: .xlsx)
        let read = try Workbook(data: out).sheets[0]
        #expect(read.conditionalFormatting[0].rules[0].style == .highlight(fill: Color(hex: "C6EFCE")))
        #expect(read.conditionalFormatting[1].rules[0].style == pink, "the rule that was not edited keeps its format")
        let ids = try Package.part("xl/worksheets/sheet1.xml", of: out)
            .components(separatedBy: "dxfId=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        #expect(Set(ids).count == 2, "the two rules no longer share an entry")
    }

    /// ODS carries conditional formats too, in LibreOffice's `calcext:` form.
    @Test func odsCarriesTheRules() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        let paint = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"), text: Color(hex: "9C0006"))
        wb.sheets[0].addConditionalFormatting(.cellIs(.greaterThan, "0", paint: paint), over: "A1:A9")
        let result = try wb.write(as: .ods)
        #expect(!result.warnings.contains { $0.message.contains("conditional format") })
        let read = try Workbook(data: result.data).sheets[0]
        #expect(read.conditionalFormatting.count == 1)
        #expect(read.conditionalFormatting[0].ranges == MultiCellRange("A1:A9"))
        let rule = try #require(read.conditionalFormatting[0].rules.first)
        #expect(rule.kind == .cellIs)
        #expect(rule.operator == .greaterThan)
        #expect(rule.formulas == ["0"])
        #expect(rule.style == paint)
    }

    /// Every rule kind the model has survives a write to ODS and a read back.
    @Test func everyRuleKindSurvivesODS() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        for r in 0..<9 { ws[r, 0] = .integer(r) }
        let paint = DifferentialStyle.highlight(fill: Color(hex: "C6EFCE"))
        ws.addConditionalFormatting(.cellIs(between: "1", and: "4", paint: paint, priority: 1), over: "A1:A9")
        ws.addConditionalFormatting(.expression("$A1>3", paint: paint, priority: 2), over: "A1:A9")
        ws.addConditionalFormatting(.contains("x", paint: paint, anchoredAt: "A1", priority: 3), over: "A1:A9")
        ws.addConditionalFormatting(.begins(with: "y", paint: paint, anchoredAt: "A1", priority: 4), over: "A1:A9")
        ws.addConditionalFormatting(.ends(with: "z", paint: paint, anchoredAt: "A1", priority: 5), over: "A1:A9")
        ws.addConditionalFormatting(.top(3, paint: paint, priority: 6), over: "A1:A9")
        ws.addConditionalFormatting(.top(10, paint: paint, bottom: true, percent: true, priority: 7), over: "A1:A9")
        ws.addConditionalFormatting(.aboveAverage(false, paint: paint, priority: 8), over: "A1:A9")
        ws.addConditionalFormatting(.duplicates(paint: paint, priority: 9), over: "A1:A9")
        ws.addConditionalFormatting(.duplicates(paint: paint, unique: true, priority: 10), over: "A1:A9")
        ws.addConditionalFormatting(ConditionalFormattingRule(kind: .containsBlanks, priority: 11, style: paint), over: "A1:A9")
        ws.addConditionalFormatting(ConditionalFormattingRule(kind: .containsErrors, priority: 12, style: paint), over: "A1:A9")
        ws.addConditionalFormatting(ConditionalFormattingRule(kind: .timePeriod, priority: 13, style: paint, timePeriod: "lastWeek"), over: "A1:A9")
        ws.addConditionalFormatting(.colorScale(.threeColor(from: .white, through: Color(hex: "FFEB84"), to: Color(hex: "63BE7B")), priority: 14), over: "A1:A9")
        ws.addConditionalFormatting(.dataBar(DataBar(color: Color(hex: "638EC6")), priority: 15), over: "A1:A9")
        ws.addConditionalFormatting(.iconSet(.threeBand(), priority: 16), over: "A1:A9")
        wb.sheets[0] = ws

        let read = try Workbook(data: try wb.write(as: .ods).data).sheets[0]
        let before = ws.conditionalFormatting.flatMap(\.rules).sorted { $0.priority < $1.priority }
        let after = read.conditionalFormatting.flatMap(\.rules).sorted { $0.priority < $1.priority }
        #expect(before.map(\.kind) == after.map(\.kind))
        for (a, b) in zip(before, after) {
            #expect(a.style == b.style, "\(a.kind) keeps what it paints")
            #expect(a.formulas == b.formulas, "\(a.kind) keeps its formulas")
            #expect(a.colorScale == b.colorScale && a.dataBar == b.dataBar && a.iconSet == b.iconSet, "\(a.kind) keeps its scale")
            #expect(a.rank == b.rank && a.bottom == b.bottom && a.percent == b.percent, "\(a.kind) keeps its rank")
            #expect(a.timePeriod == b.timePeriod && a.text == b.text, "\(a.kind) keeps its period / text")
        }
    }
}

/// Gradients — the fill kind that is not a pattern.
@Suite struct GradientFillTests {
    // openpyxl: styles/tests/test_fills.py::TestGradientFill::test_ctor
    // openpyxl: styles/tests/test_fills.py::TestGradientFill::test_serialise
    @Test func linearAndPathGradientsRoundTrip() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = 1; ws["A2"] = 2
        let linear = GradientFill(from: .white, to: Color(hex: "BFD7F5"), degree: 90)
        let path = GradientFill.path(from: Color(hex: "FFF2CC"), to: Color(hex: "F8696B"), inset: 0.5)
        ws.style("A1") { $0.fill = .gradient(linear) }
        ws.style("A2") { $0.fill = .gradient(path) }
        wb.sheets[0] = ws

        let data = try wb.data(as: .xlsx)
        let styles = try Package.part("xl/styles.xml", of: data)
        #expect(styles.contains("<gradientFill degree=\"90\"><stop position=\"0\"><color rgb=\"FFFFFFFF\"/></stop>"))
        #expect(styles.contains("<gradientFill type=\"path\" left=\"0.5\" right=\"0.5\" top=\"0.5\" bottom=\"0.5\">"))

        let again = try Workbook(data: data).sheets[0]
        #expect(again.style("A1").fill == .gradient(linear))
        #expect(again.style("A2").fill == .gradient(path))
        #expect(again.style("A1").fill.foregroundColor == .white, "the first stop reads as the foreground")
    }

    /// A gradient has no ODF equivalent here; the substitution is reported.
    @Test func odsSubstitutesTheFirstStop() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].style("A1") { $0.fill = .gradient(GradientFill(from: .white, to: .black)) }
        let result = try wb.write(as: .ods)
        #expect(result.warnings.contains { $0.message.contains("gradient") })
    }
}
