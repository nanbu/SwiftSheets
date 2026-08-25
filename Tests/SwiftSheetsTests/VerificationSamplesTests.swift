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
        var report = "# SwiftSheets 変換レポート\n\n入力: \(Self.sourceName)（LibreOffice が書いた ODF）\n\n"
        report += "## 読み込み\n\n- シート: \(wb.sheetNames.joined(separator: " / "))\n"
        report += "- 警告: \(readWarnings.isEmpty ? "なし" : "")\n"
        for w in readWarnings { report += "  - \(w.kind): \(w.description)\n" }

        // the source must have survived LibreOffice with everything the samples are meant to show
        #expect(wb.sheetNames == ["売上明細", "月次サマリ", "社員名簿", "書式見本", "補足データ"])
        let sales = try #require(wb.sheets["売上明細"])
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
        #expect(wb.sheets["補足データ"]?.state == .hidden)
        #expect(wb.sheets["社員名簿"]?["A2"] == .text("0012"), "leading zero kept as text")
        #expect(wb.sheets["書式見本"]?["E24"]?.textValue?.contains("𠮷") == true, "surrogate pair")

        // the one thing the sample sets by hand, so freeze panes can be checked in Excel / Numbers too
        report += "\n## サンプル補正\n\n- 枠固定: LibreOffice の変換で失われるため、スクリプトが「売上明細」A4 と「月次サマリ」A4 に再設定した（それ以外はすべて入力ファイル由来）\n"
        wb.sheets["売上明細"]?.freezePanes = CellRef("A4")
        wb.sheets["月次サマリ"]?.freezePanes = CellRef("A4")

        for (name, format) in [("02-swiftsheets.ods", SheetFormat.ods), ("03-swiftsheets.xlsx", .xlsx), ("04-swiftsheets.numbers", .numbers)] {
            let result = try wb.write(as: format)
            try result.data.write(to: dir.appendingPathComponent(name))
            report += "\n## \(name)\n\n- バイト数: \(result.data.count)\n- 警告: \(result.warnings.isEmpty ? "なし" : "\(result.warnings.count) 件")\n"
            var counts: [String: Int] = [:]
            for w in result.warnings { counts["\(w.kind)", default: 0] += 1 }
            for (kind, n) in counts.sorted(by: { $0.key < $1.key }) { report += "  - \(kind): \(n) 件\n" }
            for w in Array(result.warnings.prefix(8)) { report += "    - \(w.description)\n" }
            if result.warnings.count > 8 { report += "    - …ほか \(result.warnings.count - 8) 件\n" }
            if let s = result.suggestion { report += "- 提案: \(s.message)\n" }

            // every output must read back with the values intact
            if format == .numbers {
                let doc = try NumbersDocument(data: result.data)
                #expect(doc.integrityProblems().isEmpty, "\(doc.integrityProblems().prefix(5))")
            }
            let back = try Workbook(data: result.data)
            #expect(back.sheetNames.contains("売上明細"), "\(name)")
            let s = try #require(back.sheets["売上明細"])
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
                #expect(back.sheets["補足データ"]?.state == .hidden, "\(name) hidden sheet")
            }
        }
        try Data(report.utf8).write(to: dir.appendingPathComponent("conversion-report.md"))
    }
}
