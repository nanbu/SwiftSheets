import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The format-support matrix of `docs/format-support.html`, as a test.
///
/// One workbook carries everything the model can say. It is written to each format and read back, and what came
/// home is compared with what went out. The published table is that measurement, so this test is what keeps the
/// table honest: change a codec and the profile below changes with it, or the test says so.
@Suite struct FormatSupportTests {
    /// A workbook that exercises every feature the matrix lists.
    static func kitchenSink() -> Workbook {
        var wb = Workbook()
        wb.metadata.title = "全部入り"
        wb.customProperties["部署"] = .text("経理")
        wb.definedNames["Rate"] = "0.08"
        wb.protection.lockStructure = true

        var d = wb.sheets[0]
        d.name = "Data"
        d.append([CellValue.text("Region"), .text("Product"), .text("Qty"), .text("Price")])
        for i in 0..<8 {
            d.append([CellValue.text(["East", "West", "North"][i % 3]), .text(i.isMultiple(of: 2) ? "A" : "B"),
                      .integer(i + 1), .number(Decimal(i) + Decimal(string: "0.5")!)])
        }
        d["F1"] = Formula("=SUM(C2:C9)")
        d.table.arrayFormulas[CellRef("G1")!] = CellRange("G1:G8")!
        d["G1"] = Formula("=C2:C9*2")
        d["H1"] = "リンク"
        d[cell: "H1"].hyperlink = Hyperlink(target: "https://example.com/")
        d["H2"] = "メモつき"
        d[cell: "H2"].comment = CellNote("これはメモ", author: "作者")
        d["H3"] = .richText([TextRun("赤", font: Font(bold: true)), TextRun("青")])
        d.merge("A11:B12")
        d["A11"] = "結合"
        d.style("A1:D1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "DDEBF7")); $0.alignment.horizontal = .center }
        d.style("D2:D9") { $0.numberFormat = "#,##0.00" }
        d.setWidth(18, ofColumn: 0)
        d.setHeight(24, ofRow: 0)
        d.groupRows(3...5, outlineLevel: 1)
        d.freezePanesA1 = "A2"
        d.autoFilterA1 = "A1:D9"
        d.filterColumns = [FilterColumn(column: 0, values: ["East"])]
        d.sortState = SortState(range: CellRange("A2:D9")!, conditions: [SortCondition(range: CellRange("C2:C9")!, descending: true)])
        d.addExcelTable(named: "Sales", over: "A1:D9")
        d.dataValidations = [DataValidation.list("\"A,B\"", over: MultiCellRange("B2:B9")!, rejects: true)]
        let red = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"), text: Color(hex: "9C0006"))
        d.addConditionalFormatting(.cellIs(.greaterThan, "5", paint: red, priority: 1), over: "C2:C9")
        d.addConditionalFormatting(.colorScale(.twoColor(from: .white, to: Color(hex: "63BE7B")), priority: 2), over: "D2:D9")
        d.addConditionalFormatting(.dataBar(DataBar(color: Color(hex: "638EC6")), priority: 3), over: "C2:C9")
        d.addConditionalFormatting(.iconSet(.threeBand(), priority: 4), over: "D2:D9")
        d.protection.enabled = true
        d.protectedRanges = [ProtectedRange(name: "open", ranges: MultiCellRange("A2:A9")!)]
        d.scenarios = ScenarioList([Scenario(name: "強気", cells: [Scenario.InputCell("C2", "99")!])])
        d.rowBreaks = [6]
        d.columnBreaks = [3]
        d.headerFooter.oddHeader = "&L社外秘&R&P"
        d.pageSetup.orientation = .landscape
        d.pageSetup.paperSize = 9
        d.printOptions.gridLines = true
        d.setPrintArea("A1:D9")
        d.printTitleRows = 0...0
        d.definedNames["Local"] = "$A$1"
        d.tabColor = "FF0000"
        wb.sheets[0] = d

        // what only OpenDocument has (spec Appendix B.17)
        wb.epoch = .mac1904
        wb.calculationSettings.useRegularExpressions = true
        wb.calculationSettings.nullYear = 1930
        wb.labelRanges = [LabelRange(labels: CellRange("Data!A1:D1")!, data: CellRange("Data!A2:D9")!, orientation: .column)]
        wb.consolidation = Consolidation(function: .sum, sources: [CellRange("Data!A1:D9")!],
                                         target: CellRef("A20")!, targetSheet: "Data", useLabels: .both)
        wb.sheets[0].table.detective[CellRef("F1")!] = CellDetective(
            highlighted: [CellDetective.HighlightedRange(range: CellRange("Data!C2:C9"), direction: .fromSameTable)],
            operations: [CellDetective.Operation(.tracePrecedents, index: 0)])
        wb.sheets[0]["I1"] = .number(Decimal(string: "1234.5")!)
        wb.sheets[0].style("I1") { $0.numberFormat = "[$¥-411]#,##0.00" }

        wb.addSheet(named: "Pivot")
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A3")!, summarizing: CellRange("A1:D9")!,
                             on: "Data", rows: ["Region"], columns: ["Product"], values: [("Qty", .sum)])
        wb.addSheet(named: "Hidden")
        wb.sheets[2].isHidden = true
        wb.sheets[2]["A1"] = "隠しシート"
        // several tables on one canvas: only Numbers keeps them
        wb.addSheet(named: "Multi")
        wb.sheets[3]["A1"] = "表1"
        let second = wb.sheets[3].addTable(named: "表2", anchor: CellRef("D1")!)
        wb.sheets[3].tables[second]["A1"] = "二枚目"
        return wb
    }

    /// The 46 rows of the published table, in its order. Each says whether the feature came home.
    static func profile(of workbook: Workbook) -> [String: Bool] {
        let s = workbook.sheets["Data"] ?? workbook.sheets[0]
        let pivot = workbook.sheets["Pivot"]
        let rules = s.conditionalFormatting.flatMap(\.rules)
        var richText = false
        if case .richText? = s["H3"] { richText = true }
        return [
            "値": s["A2"] == .text("East"),
            "数式": s["F1"]?.formula != nil,
            "配列数式": !s.table.arrayFormulas.isEmpty,
            "結合": s.merges.contains(CellRange("A11:B12")!),
            "書式・太字": s.style("A1").font.bold,
            "書式・塗り": s.style("A1").fill.foregroundColor != nil,
            "配置": s.style("A1").alignment.horizontal == .center,
            "表示形式": s.style("D2").numberFormat == "#,##0.00",
            "列幅": s.columnDimension(0).width != nil,
            "行高": s.rowDimension(0).height != nil,
            "グループ化": s.rowDimensions.values.contains { $0.outlineLevel > 0 },
            "ウィンドウ枠固定": s.freezePanes != nil,
            "ハイパーリンク": s.cell("H1")?.hyperlink != nil,
            "メモ": s.cell("H2")?.comment != nil,
            "リッチテキスト": richText,
            "条件付き書式": rules.contains { $0.kind == .cellIs },   // the plain rule; the three richer kinds have rows of their own
            "CF・カラースケール": rules.contains { $0.kind == .colorScale },
            "CF・データバー": rules.contains { $0.kind == .dataBar },
            "CF・アイコンセット": rules.contains { $0.kind == .iconSet },
            "入力規則": !s.dataValidations.isEmpty,
            "名前付きの表": !s.excelTables.isEmpty,
            "オートフィルタ": s.autoFilter != nil,
            "絞り込み条件": !s.filterColumns.isEmpty,
            "並べ替えの記録": s.sortState != nil,
            "ピボット表": !(pivot?.pivotTables.isEmpty ?? true),
            "シート保護": s.protection.enabled,
            "保護範囲": !s.protectedRanges.isEmpty,
            "シナリオ": !s.scenarios.isEmpty,
            "印刷・ヘッダフッタ": !s.headerFooter.isEmpty,
            "印刷・向き": s.pageSetup.orientation == .landscape,
            "印刷・範囲": !s.printArea.isEmpty,
            "印刷・タイトル行": s.printTitleRows != nil,
            "改ページ": !s.rowBreaks.isEmpty,
            "タブ色": s.tabColor != nil,
            "定義名・ブック": !workbook.definedNames.isEmpty,
            "定義名・シート": !s.definedNames.isEmpty,
            "ブック保護": workbook.protection.lockStructure,
            "文書の自由項目": !workbook.customProperties.isEmpty,
            "隠しシート": workbook.sheets.contains { $0.isHidden },
            "1シート複数テーブル": (workbook.sheets["Multi"]?.tables.count ?? 0) > 1,
            // ODF only (Appendix B.17)
            "ラベル範囲": !workbook.labelRanges.isEmpty,
            "統合の定義": workbook.consolidation != nil,
            "探偵の矢印": !s.tables.allSatisfy(\.detective.isEmpty),
            "計算設定": workbook.calculationSettings.useRegularExpressions,
            "日付の原点": workbook.epoch == .mac1904,
            "通貨のセル種別": s.style("I1").numberFormat.contains("¥"),
        ]
    }

    /// What each format is *expected* to lose. Everything not named here has to survive.
    static let expectedLosses: [SheetFormat: Set<String>] = [
        .xlsx: ["1シート複数テーブル", "ラベル範囲", "統合の定義", "探偵の矢印", "計算設定"],
        .ods: ["保護範囲", "シナリオ", "タブ色", "ブック保護", "1シート複数テーブル"],
        .numbers: [
            "配列数式", "グループ化", "ハイパーリンク", "メモ", "リッチテキスト",
            "CF・カラースケール", "CF・データバー", "CF・アイコンセット",
            "入力規則", "名前付きの表", "オートフィルタ", "絞り込み条件", "並べ替えの記録", "ピボット表",
            "シート保護", "保護範囲", "シナリオ",
            "印刷・ヘッダフッタ", "印刷・向き", "印刷・範囲", "印刷・タイトル行", "改ページ", "タブ色",
            "定義名・ブック", "定義名・シート", "ブック保護", "文書の自由項目", "隠しシート",
            "ラベル範囲", "統合の定義", "探偵の矢印", "計算設定",
        ],
    ]

    /// How many warnings each format's write returns for this workbook — the number the published table quotes.
    static let expectedWarningCount: [SheetFormat: Int] = [.xlsx: 5, .ods: 8, .numbers: 24]

    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func matchesThePublishedTable(_ format: SheetFormat) throws {
        let wb = Self.kitchenSink()
        let result = try wb.write(as: format)
        let back = try Workbook(data: result.data)
        let survived = Self.profile(of: back)
        let expected = Self.expectedLosses[format]!

        let lost = Set(survived.filter { !$0.value }.keys)
        #expect(lost == expected, """
            \(format.rawValue): the format-support table says these are lost — \(expected.sorted())
            but the measurement says — \(lost.sorted())
            (unexpectedly lost: \(lost.subtracting(expected).sorted()); \
            unexpectedly kept: \(expected.subtracting(lost).sorted()))
            docs/format-support.html has to be updated with the code.
            """)
        #expect(survived.count == 46, "the published table has 46 rows")

        // nothing is dropped in silence: every loss is answered by a warning
        #expect(result.warnings.count == Self.expectedWarningCount[format]!,
                "\(format.rawValue): \(result.warnings.count) warning(s) — \(result.warnings.map(\.message))")
        if !expected.isEmpty { #expect(!result.warnings.isEmpty) }
    }

    /// The one feature Excel cannot hold is the one Numbers exists for, and the other way round.
    @Test func theFormatsAreNotOrderedByStrength() throws {
        let wb = Self.kitchenSink()
        let numbers = Self.profile(of: try Workbook(data: try wb.write(as: .numbers).data))
        let xlsx = Self.profile(of: try Workbook(data: try wb.write(as: .xlsx).data))
        #expect(numbers["1シート複数テーブル"] == true)
        #expect(xlsx["1シート複数テーブル"] == false)
    }
}
