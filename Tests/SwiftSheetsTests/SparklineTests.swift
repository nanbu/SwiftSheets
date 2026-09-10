import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Sparklines (spec Appendix B.79): read from the worksheet's `x14:sparklineGroups` extension and from
/// LibreOffice's `calcext:sparkline-groups`, written by both, carried as bytes in XLSX until changed.
@Suite(.serialized) struct SparklineTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let xlsx = fixtures.appendingPathComponent("drawings/libreoffice-sparklines.xlsx")
    static let ods = fixtures.appendingPathComponent("ods/libreoffice-sparklines.ods")
    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsSparklines", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "Trend"
        for (c, v) in [3, 1, 4, 1, 5, 9, 2, 6].enumerated() { wb.sheets[0][CellRef(row: 1, column: c + 1)] = .integer(v); wb.sheets[0][CellRef(row: 2, column: c + 1)] = .integer(v - 4) }
        wb.sheets[0].addSparkline(.line, data: "A1:H1", at: "I1")
        var wins = SparklineGroup(.stacked, dataRange: "'Trend'!A2:H2", at: CellRef("I2")!)
        wins.color = .theme(4)
        wins.negativeColor = Color(hex: "FF0000")
        wins.showsNegativePoints = true
        wins.emptyCells = .gap
        wb.sheets[0].sparklines.append(wins)
        return wb
    }

    static func check(_ groups: [SparklineGroup], _ label: String) {
        #expect(groups.count == 2, "\(label): \(groups)")
        guard groups.count == 2 else { return }
        #expect(groups[0].kind == .line && groups[0].sparklines.count == 1 && groups[0].sparklines[0].location == CellRef("I1"), Comment(rawValue: label))
        #expect(groups[0].sparklines[0].dataRange.replacingOccurrences(of: "$", with: "").hasSuffix("A1:H1"), "\(label): \(groups[0].sparklines[0].dataRange)")
        // XLSX keeps the theme colour as a theme colour; ODS writes it resolved — either way it is the same blue
        #expect(groups[1].kind == .stacked && groups[1].color.flatMap { Workbook().rgb(of: $0) } == "FF4472C4" && groups[1].negativeColor == .rgb("FFFF0000"), "\(label): \(groups[1])")
        #expect(groups[1].showsNegativePoints && groups[1].emptyCells == .gap && groups[1].sparklines[0].location == CellRef("I2"), "\(label): \(groups[1])")
    }

    @Test func readsLibreOfficesSparklinesFromXLSX() throws {
        let sheet = try Workbook(contentsOf: Self.xlsx).sheets[0]
        #expect(sheet.sparklines.map(\.kind) == [.line, .column])
        #expect(sheet.sparklines[0].color == .rgb("FF376092") && sheet.sparklines[0].negativeColor == .rgb("FFFF0000"))
        #expect(sheet.sparklines[0].sparklines == [SparklineGroup.Sparkline(dataRange: "S!A1:H1", location: CellRef("I1")!)])
        #expect(sheet.sparklines[1].showsHighPoint && sheet.sparklines[1].highColor == .rgb("FFFF0000") && sheet.sparklines[1].sparklines[0].location == CellRef("I2"))
        #expect(sheet.preserved.sparklines == sheet.sparklines)
    }

    @Test func readsLibreOfficesSparklinesFromODS() throws {
        let sheet = try Workbook(contentsOf: Self.ods).sheets[0]
        #expect(sheet.sparklines.map(\.kind) == [.line, .column], "\(sheet.sparklines.map(\.kind))")
        #expect(sheet.sparklines[0].color == .rgb("FF376092") && sheet.sparklines[0].emptyCells == .gap)
        #expect(sheet.sparklines[0].sparklines.first?.location == CellRef("I1") && sheet.sparklines[0].sparklines.first?.dataRange.replacingOccurrences(of: "'", with: "") == "S!A1:H1", "\(sheet.sparklines[0].sparklines)")
        #expect(sheet.sparklines[1].showsHighPoint && sheet.sparklines[1].emptyCells == .zero && sheet.sparklines[1].lineWidth == nil)
    }

    @Test func untouchedSparklinesAreBytesAndAChangeRegeneratesThem() throws {
        let source = try Package.part("xl/worksheets/sheet1.xml", of: Data(contentsOf: Self.xlsx))
        var wb = try Workbook(contentsOf: Self.xlsx)
        let same = try wb.write(as: .xlsx)
        let sameSheet = try Package.part("xl/worksheets/sheet1.xml", of: same.data)
        let sourceExt = source[source.range(of: "<extLst>")!.lowerBound...]
        #expect(sameSheet.hasSuffix(String(sourceExt)), "the extension list travels as bytes")
        wb.sheets[0].sparklines[0].color = Color(hex: "00FF00")
        wb.sheets[0].addSparkline(.column, data: "A1:H1", at: "J1")
        let changed = try wb.write(as: .xlsx)
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: changed.data)
        #expect(sheet.components(separatedBy: "<extLst").count == 2 && sheet.contains("<x14:colorSeries rgb=\"FF00FF00\"/>") && sheet.contains("<xm:f>Trend!A1:H1</xm:f>") == false)
        #expect(sheet.contains("<xm:f>S!A1:H1</xm:f>") && sheet.contains("<xm:sqref>J1</xm:sqref>"))
        let back = try Workbook.read(changed.data, format: .xlsx).workbook.sheets[0]
        #expect(back.sparklines.count == 3 && back.sparklines[0].color == .rgb("FF00FF00") && back.sparklines[2].kind == .column)
    }

    @Test func sparklinesRoundTripThroughXLSXAndODS() throws {
        let xlsx = try Self.workbook().write(as: .xlsx)
        #expect(xlsx.warnings.isEmpty, "\(xlsx.warnings.map(\.message))")
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: xlsx.data).contains("<xm:f>Trend!A1:H1</xm:f>"), "an unqualified range gains the sheet")
        Self.check(try Workbook.read(xlsx.data, format: .xlsx).workbook.sheets[0].sparklines, "xlsx")
        let ods = try Self.workbook().write(as: .ods)
        #expect(ods.warnings.isEmpty, "\(ods.warnings.map(\.message))")
        let content = try Package.part("content.xml", of: ods.data)
        #expect(content.contains("<calcext:sparkline-group ") && content.contains("calcext:type=\"stacked\"") && content.contains("calcext:color-series=\"#4472c4\""))
        Self.check(try Workbook.read(ods.data, format: .ods).workbook.sheets[0].sparklines, "ods")
        let numbers = try Self.workbook().write(as: .numbers)
        #expect(numbers.warnings.contains { $0.kind == .dropped && $0.message.contains("2 sparkline group(s) dropped") }, "\(numbers.warnings.map(\.message))")
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeReadsBothWritersSparklines() throws {
        let ods = Self.tmp.appendingPathComponent("sparklines.ods")
        try Self.workbook().write(to: ods, as: .ods)
        let xlsx = try ODSImageTests.convert(ods, to: "xlsx")
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: Data(contentsOf: xlsx))
        #expect(sheet.contains("<x14:sparklineGroup") && sheet.contains("type=\"stacked\""), "LibreOffice wrote: \(sheet.suffix(600))")
        Self.check(try Workbook(contentsOf: xlsx).sheets[0].sparklines, "ods→LibreOffice→xlsx")
        let x = Self.tmp.appendingPathComponent("sparklines.xlsx")
        try Self.workbook().write(to: x, as: .xlsx)
        let backODS = try ODSImageTests.convert(x, to: "ods")
        #expect(try Package.part("content.xml", of: Data(contentsOf: backODS)).contains("calcext:sparkline-group"))
        Self.check(try Workbook(contentsOf: backODS).sheets[0].sparklines, "xlsx→LibreOffice→ods")
    }
}
