import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Three lists that will grow after 1.0 are structs with static members, not enums (spec Appendix B.69):
/// `Chart.Kind`, `SheetImage.Format` and `DateEpoch`. The way they are spelled does not change; what changes is
/// that a value the library did not name can exist — a chart kind read from a file, a date origin ODF chose.
struct ReservedEnumTests {
    @Test func theSpellingsAreUnchanged() {
        let chart = Chart(.column, title: "t")
        #expect(chart.kind == .column && chart.kind != .pie)
        #expect(Chart.Kind.drawable == [.column, .bar, .line, .pie])
        #expect(Chart.Kind(rawValue: "scatterChart").isDrawable == false)
        #expect(SheetImage.Format.jpeg.contentType == "image/jpeg")
        #expect(SheetImage.Format(rawValue: "bmp").contentType == "image/bmp")
        var wb = Workbook()
        wb.epoch = .mac1904
        #expect(wb.epoch == .mac1904 && wb.epoch.isExcelOrigin)
        #expect(DateEpoch.windows1900.origin == CivilDate(year: 1899, month: 12, day: 30)!)
        // the two named origins still convert exactly as before
        #expect(CivilDate(year: 2026, month: 9, day: 1)!.serial(epoch: .mac1904) == 44804)
        #expect(CivilDate(year: 1900, month: 3, day: 1)!.serial(epoch: .windows1900) == 61)
        #expect(CivilDate(year: 1900, month: 2, day: 28)!.serial(epoch: .windows1900) == 59)
    }

    @Test func anOriginOfItsOwnHasNoPhantomDay() {
        let epoch = DateEpoch(origin: CivilDate(year: 2000, month: 1, day: 1)!)
        #expect(!epoch.isExcelOrigin)
        #expect(CivilDate(year: 2000, month: 1, day: 31)!.serial(epoch: epoch) == 30)
        #expect(CellValue(serial: 30, epoch: epoch) == .date(CivilDateTime(date: CivilDate(year: 2000, month: 1, day: 31)!)))
    }

    /// ODS carries any origin; Excel re-bases it onto 1900 and says so, and the dates land on the same day.
    @Test func odsKeepsAnyOriginAndExcelReBasesIt() throws {
        var wb = Workbook()
        wb.epoch = DateEpoch(origin: CivilDate(year: 2000, month: 1, day: 1)!)
        wb.sheets[0]["A1"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 11)!))
        let ods = try wb.write(as: .ods)
        #expect(!ods.warnings.contains { $0.message.contains("date origin") })
        let back = try Workbook.read(ods.data, format: .ods)
        #expect(back.workbook.epoch == wb.epoch)
        #expect(!back.warnings.contains { $0.message.contains("date origin") })
        #expect(back.workbook.sheets[0]["A1"] == wb.sheets[0]["A1"])

        let xlsx = try wb.write(as: .xlsx)
        let w = xlsx.warnings.filter { $0.message.contains("date origin 2000-01-01 is written as the 1900 system") }
        #expect(w.count == 1 && w[0].kind == .degraded)
        let excel = try Workbook.read(xlsx.data, format: .xlsx)
        #expect(excel.workbook.epoch == .windows1900)
        #expect(excel.workbook.sheets[0]["A1"] == wb.sheets[0]["A1"], "a civil date lands on the same day whatever the origin")
    }

    /// A kind the writer cannot draw is refused out loud, not written as an empty chart.
    @Test func anUndrawableKindIsReported() throws {
        var wb = Workbook()
        var chart = Chart(Chart.Kind(rawValue: "scatterChart"))
        chart.addSeries(values: "B2:B4")
        wb.sheets[0].addChart(chart, over: "D2:K16")
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("a scatterChart chart was not written") })
        #expect(!String(decoding: result.data, as: UTF8.self).contains("chartSpace"))
    }
}
