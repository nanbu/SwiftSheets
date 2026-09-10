import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Excel 2010's conditional-format extension (spec Appendix B.82): a data bar's negative and axis colours, axis
/// position, direction, solid fill and border, and an icon set's hand-picked icons — read out of `x14:` and
/// written back beside the 2007 rules; ODS carries what LibreOffice's data bar can say.
@Suite(.serialized) struct ConditionalExtensionTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/preservation/libreoffice-databar-x14.xlsx")
    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsCFExt", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func workbook() -> Workbook {
        var wb = Workbook()
        for (i, v) in [-5, 3, 8, -2, 10].enumerated() { wb.sheets[0][CellRef(row: i + 1, column: 1)] = .integer(v) }
        var bar = DataBar(color: Color(hex: "00B050"), minLength: 5, maxLength: 95)
        bar.negativeColor = Color(hex: "FF0000")
        bar.axisColor = Color(hex: "0000FF")
        bar.axisPosition = .middle
        bar.direction = .leftToRight
        bar.isGradient = false
        bar.borderColor = Color(hex: "008000")
        wb.sheets[0].conditionalFormatting.append(ConditionalFormatting(ranges: MultiCellRange("A1:A5")!, rules: [.dataBar(bar, priority: 1)]))
        var icons = IconSet(name: "3TrafficLights1", values: [.percent(0), .percent(33), .percent(67)])
        icons.customIcons = [IconSet.Icon(set: "3Arrows", index: 0), IconSet.Icon(set: "3Symbols", index: 1), IconSet.Icon(set: "5Quarters", index: 4)]
        wb.sheets[0].conditionalFormatting.append(ConditionalFormatting(ranges: MultiCellRange("B1:B5")!, rules: [.iconSet(icons, priority: 2)]))
        return wb
    }

    @Test func readsLibreOfficesDataBarExtension() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        let sheet = wb.sheets[0]
        #expect(!sheet.hasUnmodelledConditionalFormats, "a rule whose extension only names an id is the model's")
        let bar = try #require(sheet.conditionalFormatting.first?.rules.first?.dataBar)
        #expect(bar.color == .rgb("FF00B050") && bar.minLength == 5 && bar.maxLength == 95)
        #expect(bar.negativeColor == .rgb("FFFF0000") && bar.axisColor == .rgb("FF0000FF") && bar.axisPosition == .middle && !bar.isGradient, "\(bar)")
        #expect(bar.usesExtension && sheet.preserved.unmatchedConditionalExtensions == 0)
    }

    @Test func theExtensionIsRegeneratedBesideTheRules() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: result.data)
        let idInRule = try #require(sheet.range(of: "<x14:id>").map { sheet[$0.upperBound...].prefix(38) })
        #expect(sheet.contains("<x14:cfRule type=\"dataBar\" id=\"\(idInRule)\">"), "the rule and the extension share the id")
        #expect(sheet.contains("<x14:negativeFillColor rgb=\"FFFF0000\"/>") && sheet.contains("axisPosition=\"middle\"") && sheet.contains("gradient=\"0\""))
        #expect(sheet.components(separatedBy: "<extLst>").count == 3, "one in the rule, one on the sheet: \(sheet.components(separatedBy: "<extLst>").count - 1)")
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back.conditionalFormatting.first?.rules.first?.dataBar == wb.sheets[0].conditionalFormatting.first?.rules.first?.dataBar)
    }

    @Test func dataBarsAndCustomIconsRoundTripThroughXLSX() throws {
        let result = try Self.workbook().write(as: .xlsx)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: result.data)
        #expect(sheet.contains("<x14:cfIcon iconSet=\"5Quarters\" iconId=\"4\"/>") && sheet.contains("custom=\"1\""))
        #expect(sheet.contains("direction=\"leftToRight\"") && sheet.contains("border=\"1\"") && sheet.contains("<x14:borderColor rgb=\"FF008000\"/>"))
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back.conditionalFormatting.map(\.rules) == Self.workbook().sheets[0].conditionalFormatting.map(\.rules), "\(back.conditionalFormatting)")
        // a second save regenerates the same extension: nothing dangles and nothing is reported
        let again = try Workbook.read(result.data, format: .xlsx).workbook.write(as: .xlsx)
        #expect(again.warnings.isEmpty, "\(again.warnings.map(\.message))")
    }

    @Test func odsCarriesTheDataBarsWordsAndSaysWhatItCannot() throws {
        let result = try Self.workbook().write(as: .ods)
        let content = try Package.part("content.xml", of: result.data)
        #expect(content.contains("calcext:negative-color=\"#ff0000\"") && content.contains("calcext:axis-position=\"middle\"") && content.contains("calcext:axis-color=\"#0000ff\"") && content.contains("calcext:gradient=\"false\""))
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("ODF has no custom icons") }, "\(result.warnings.map(\.message))")
        let back = try Workbook.read(result.data, format: .ods).workbook.sheets[0]
        let bar = try #require(back.conditionalFormatting.first { $0.rules.first?.dataBar != nil }?.rules.first?.dataBar)
        #expect(bar.negativeColor == .rgb("FFFF0000") && bar.axisColor == .rgb("FF0000FF") && bar.axisPosition == .middle && !bar.isGradient, "\(bar)")
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeReadsTheExtensionWrittenHere() throws {
        // LibreOffice 26.2.3 aborts ("Unspecified Application Error") on any x14:iconSet, custom or not, in
        // Excel's own form (measured 2026-09-11); the judge is asked about the data bar only
        var wb = Self.workbook()
        wb.sheets[0].conditionalFormatting.removeLast()
        let file = Self.tmp.appendingPathComponent("databar.xlsx")
        try wb.write(to: file, as: .xlsx)
        let ods = try ODSImageTests.convert(file, to: "ods")
        let content = try Package.part("content.xml", of: Data(contentsOf: ods))
        #expect(content.contains("calcext:negative-color=\"#ff0000\"") && content.contains("calcext:axis-position=\"middle\""), "LibreOffice read the x14 data bar: \(content.range(of: "data-bar").map { String(content[$0.lowerBound...].prefix(300)) } ?? "no data-bar")")
    }
}
