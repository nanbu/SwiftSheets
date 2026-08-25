import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Produces the manual-verification samples of MAINTENANCE.md's release checklist: a LibreOffice-written .ods is read
/// with SwiftSheets and written back out as .ods, .xlsx and .numbers, so the three files can be opened in
/// LibreOffice, Excel and Numbers by hand. Skipped unless `SWIFTSHEETS_SAMPLES_DIR` is set — driven by
/// `scripts/make-verification-samples.sh`.
@Suite struct VerificationSamplesTests {
    static var dir: URL? { ProcessInfo.processInfo.environment["SWIFTSHEETS_SAMPLES_DIR"].map { URL(fileURLWithPath: $0) } }
    static let sourceName = "01-source-libreoffice.ods"

    @Test func convertsTheLibreOfficeSourceToEveryFormat() throws {
        guard let dir = Self.dir else { return }
        let source = dir.appendingPathComponent(Self.sourceName)
        let result = try ODSCodec.read(try Data(contentsOf: source))
        let (read, readWarnings) = (result.workbook, result.warnings)
        var wb = read
        var report = "# SwiftSheets conversion report\n\nInput: \(Self.sourceName) (the ODF LibreOffice wrote)\n\n"
        report += "## Reading\n\n- sheets: \(wb.sheetNames.joined(separator: " / "))\n"
        report += "- warnings: \(readWarnings.isEmpty ? "none" : "")\n"
        for w in readWarnings { report += "  - \(w.kind): \(w.description)\n" }

        // the source must have survived LibreOffice with everything the samples are meant to show
        #expect(wb.sheetNames == ["Sales", "Monthly", "Staff", "Formats", "Extra"])
        let sales = try #require(wb.sheets["Sales"])
        #expect(sales["A1"] == .text("2026年度 上期 売上明細"))
        #expect(sales.merges.contains(CellRange("A1:I1")!))
        // LibreOffice's headless converter writes no view settings at all (settings.xml has no Views/Tables map),
        // so freeze panes are already gone from the source file — see the report and README.
        #expect(sales.freezePanes == nil, "LibreOffice dropped the freeze panes before SwiftSheets saw the file")
        #expect(sales.autoFilter != nil, "auto filter read from the ODS")
        #expect(sales["H4"]?.formula != nil, "formulas read from the ODS")
        #expect(sales["H4"]?.cachedValue?.doubleValue == 456_000)
        #expect(sales.style("A1").font.bold && sales.style("A1").fill.patternType == .solid)
        #expect(sales.style("G4").numberFormat.contains("¥") || sales.style("G4").numberFormat.contains("#,##0"))
        #expect(sales.cell("B4")?.comment != nil, "cell note read from the ODS")
        #expect(sales.cell("E2")?.hyperlink != nil, "hyperlink read from the ODS")
        #expect(wb.sheets["Extra"]?.state == .hidden)
        #expect(wb.sheets["Staff"]?["A2"] == .text("0012"), "leading zero kept as text")
        #expect(wb.sheets["Formats"]?["E24"]?.textValue?.contains("𠮷") == true, "surrogate pair")

        // the one thing the sample sets by hand, so freeze panes can be checked in Excel / Numbers too
        report += "\n## Corrections made to the sample\n\n- frozen panes: LibreOffice drops them when it converts, so the script sets them again on Sales!A4 and Monthly!A4. Everything else comes from the input file.\n"
        wb.sheets["Sales"]?.freezePanes = CellRef("A4")
        wb.sheets["Monthly"]?.freezePanes = CellRef("A4")

        for (name, format) in [("02-swiftsheets.ods", SheetFormat.ods), ("03-swiftsheets.xlsx", .xlsx), ("04-swiftsheets.numbers", .numbers)] {
            let result = try wb.write(as: format)
            try result.data.write(to: dir.appendingPathComponent(name))
            report += "\n## \(name)\n\n- bytes: \(result.data.count)\n- warnings: \(result.warnings.isEmpty ? "none" : "\(result.warnings.count)")\n"
            var counts: [String: Int] = [:]
            for w in result.warnings { counts["\(w.kind)", default: 0] += 1 }
            for (kind, n) in counts.sorted(by: { $0.key < $1.key }) { report += "  - \(kind): \(n)\n" }
            for w in Array(result.warnings.prefix(8)) { report += "    - \(w.description)\n" }
            if result.warnings.count > 8 { report += "    - …and \(result.warnings.count - 8) more\n" }
            if let s = result.suggestion { report += "- suggestion: \(s.message)\n" }

            // every output must read back with the values intact
            if format == .numbers {
                let doc = try NumbersDocument(data: result.data)
                #expect(doc.integrityProblems().isEmpty, "\(doc.integrityProblems().prefix(5))")
            }
            let back = try Workbook(data: result.data)
            #expect(back.sheetNames.contains("Sales"), "\(name)")
            let s = try #require(back.sheets["Sales"])
            #expect(s["A1"] == .text("2026年度 上期 売上明細"), "\(name) title")
            #expect(s["B4"] == .text("株式会社山田製作所"), "\(name) Japanese text")
            #expect(s["H4"]?.cachedValue?.doubleValue == 456_000, "\(name) computed value")
            #expect(s.merges.contains(CellRange("A1:I1")!), "\(name) merge")
            if format != .numbers {
                #expect(s.style("A1").font.bold, "\(name) bold title")
                #expect(s.style("A1").fill.patternType == .solid, "\(name) title fill")
                #expect(s["H4"]?.formula != nil, "\(name) formula")
                #expect(s.autoFilter != nil, "\(name) auto filter")
                #expect(s.freezePanes == CellRef("A4"), "\(name) freeze panes")
                #expect(back.sheets["Extra"]?.state == .hidden, "\(name) hidden sheet")
            }
        }
        try Data(report.utf8).write(to: dir.appendingPathComponent("conversion-report.md"))
    }
}
