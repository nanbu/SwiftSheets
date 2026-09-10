import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// `preservationSummary.parts` — what the preserved material holds that the model does not represent, by kind
/// (spec Appendix B.77): the answer to "what will drop?" before a write is attempted.
struct PreservationInventoryTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    @Test func aWorkbookWhoseEveryPartTheModelReadListsNothing() throws {
        let wb = try Workbook(contentsOf: Self.fixtures.appendingPathComponent("preservation/charts-and-friends.xlsx"))
        let summary = wb.preservationSummary
        #expect(summary.opaquePartCount > 0, "the bytes still travel")
        #expect(summary.parts.isEmpty, "the chart, the drawing, the notes and the theme are the model's: \(summary.parts)")
        #expect(Workbook().preservationSummary.parts.isEmpty)
    }

    @Test func whatTheModelCannotHoldIsCountedByKind() throws {
        let art = try Workbook(contentsOf: Self.fixtures.appendingPathComponent("drawings/smartart-and-group.xlsx")).preservationSummary.parts
        #expect(art == [.smartArt: 1, .shapeGroup: 1], "\(art)")
        let vba = try Workbook(contentsOf: Self.fixtures.appendingPathComponent("preservation/with-vba.xlsm")).preservationSummary
        #expect(vba.hasVBAProject && vba.parts[.vbaProject] == 1, "\(vba.parts)")
        let chartSheet = try Workbook(contentsOf: Self.fixtures.appendingPathComponent("chartsheet.xlsx")).preservationSummary.parts
        #expect(chartSheet[.chartSheet] == 1 && chartSheet[.chart] == 1 && chartSheet[.drawing] == 1, "a chart sheet's chart and drawing are not a grid sheet's: \(chartSheet)")
        let links = try Workbook(contentsOf: Self.fixtures.appendingPathComponent("preservation/external-links.xlsx")).preservationSummary.parts
        #expect(links == [.externalLink: 1], "\(links)")
    }

    @Test func odsObjectsReadAsChartsAreNotListed() throws {
        let parts = try Workbook(contentsOf: Self.fixtures.appendingPathComponent("drawings/libreoffice-four-charts.ods")).preservationSummary.parts
        #expect(parts[.embeddedObject] == nil && parts[.image] == nil, "\(parts)")
        #expect(parts.keys.allSatisfy { $0 == .other }, "\(parts)")
    }

    @Test func theKindsAreNamesAndOrdered() {
        #expect(PreservedPartKind.smartArt.rawValue == "smartArt" && PreservedPartKind(rawValue: "smartArt") == .smartArt)
        #expect([PreservedPartKind.theme, .chart].sorted() == [.chart, .theme])
        let summary = PreservationSummary(sourceFormat: .xlsx, opaquePartCount: 3, hasVBAProject: false, parts: [.slicer: 2])
        #expect(summary.parts[.slicer] == 2 && PreservationSummary(sourceFormat: nil, opaquePartCount: 0, hasVBAProject: false).parts.isEmpty)
    }
}
