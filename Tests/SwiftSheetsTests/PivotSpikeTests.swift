import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// SCRATCH — measurement only, deleted before the work lands. Two questions the ground truth can answer and no
/// document can: does our container carry a pivot document unharmed, and what do the `agg_type` numbers mean?
@Suite struct PivotSpikeTests {
    static let dir: URL = {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/numbers-judge/spike")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let ground = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/numbers-judge/ground/kitchen-sink-by-numbers.numbers")

    /// The measurements need artifacts no fresh clone carries — the ground truth Numbers saved, and documents
    /// earlier tests in this suite write. Without them a test must **skip**, visibly, never pass having measured
    /// nothing (the ODSCodecTests / LibreOffice precedent).
    static var hasGround: Bool { FileManager.default.fileExists(atPath: ground.path) }
    static func hasArtifact(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appending(path: name).path) }

    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func roundTripsAPivotDocument() throws {
        let original = try Data(contentsOf: Self.ground)
        let doc = try NumbersDocument(data: original)
        let out = doc.encoded()
        print("SPIKE integrity: \(doc.integrityProblems())")
        print("SPIKE sizes: in \(original.count) out \(out.count)")
        let pivots = doc.identifiers(ofType: "TST.PivotOwnerArchive")
        print("SPIKE pivot owners: \(pivots)")
        try out.write(to: Self.dir.appending(path: "00-roundtrip.numbers"))
        // …and can we still read it back ourselves?
        let again = try NumbersDocument(data: out)
        print("SPIKE reread pivot owners: \(again.identifiers(ofType: "TST.PivotOwnerArchive"))")
    }

    /// `agg_type` is a bare uint32 Apple left unnamed. One document per value, opened by Numbers, says what each
    /// number means — the same way the fourteen `predicate_type` values were read (Appendix B.18).
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesOneDocumentPerAggType() throws {
        let original = try Data(contentsOf: Self.ground)
        for n in 0...12 {
            let doc = try NumbersDocument(data: original)
            guard let owner = doc.identifiers(ofType: "TST.PivotOwnerArchive").first else { return }
            doc.update(owner) { m in
                guard var list = m.message("aggregate_columns") else { return }
                var aggs = list.messages("aggregates")
                guard !aggs.isEmpty else { return }
                aggs[0].set("agg_type", int: n)
                list.set("aggregates", messages: aggs)
                m.set("aggregate_columns", message: list)
                // a fresh refresh uid, so Numbers cannot mistake this for the document it already computed
                m.set("refresh_timestamp", double: 809376861.0 + Double(n))
            }
            try doc.encoded().write(to: Self.dir.appending(path: "agg-\(String(format: "%02d", n)).numbers"))
        }
        print("SPIKE wrote agg-00…agg-12")
    }

    /// The same sweep, but telling Numbers the **rules** changed: the three change tokens are re-minted and the
    /// group-by's cached accumulators are thrown away, so nothing is left for Numbers to believe but the rule.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesOneDocumentPerAggTypeWithAFreshRule() throws {
        let original = try Data(contentsOf: Self.ground)
        for n in 0...12 {
            let doc = try NumbersDocument(data: original)
            guard let owner = doc.identifiers(ofType: "TST.PivotOwnerArchive").first else { return }
            doc.update(owner) { m in
                guard var list = m.message("aggregate_columns") else { return }
                var aggs = list.messages("aggregates")
                guard !aggs.isEmpty else { return }
                aggs[0].set("agg_type", int: n)
                list.set("aggregates", messages: aggs)
                m.set("aggregate_columns", message: list)
                m.set("refresh_uid", message: NumbersUUID.random().uuid)
                m.set("aggregate_rule_change_uid", message: NumbersUUID.random().uuid)
                m.set("row_column_rule_change_uid", message: NumbersUUID.random().uuid)
                m.set("refresh_timestamp", double: 809376861.0 + Double(n))
            }
            // every cached accumulation the group-bys hold, gone
            for g in doc.identifiers(ofType: "TST.GroupByArchive") {
                doc.update(g) { $0.remove("aggregator"); $0.remove("aggregator_ref") }
            }
            try doc.encoded().write(to: Self.dir.appending(path: "aggu-\(String(format: "%02d", n)).numbers"))
        }
        print("SPIKE wrote aggu-00…aggu-12")
    }

    /// The question the whole approach turns on. Numbers recalculates a document an **older** Numbers wrote and
    /// trusts one its own version wrote — that is why formulas written from the 14.1-era template compute at all
    /// (Appendix B.18). If the same holds for a pivot, then a writer owes Numbers the *rules* and the source rows,
    /// and Numbers does the summing. The ground truth is stamped 15.3.1; here it is stamped as the template is,
    /// with every cached accumulation removed, so anything on screen has to have been recomputed.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func asksWhetherAnOlderDocumentIsRecomputed() throws {
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        guard let oldHistory = templateDoc.blob("Metadata/BuildVersionHistory.plist") else {
            print("SPIKE the template has no BuildVersionHistory"); return
        }
        for (label, stripAggregators) in [("kept", false), ("stripped", true)] {
            let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
            doc.setBlob("Metadata/BuildVersionHistory.plist", oldHistory)
            if stripAggregators {
                for g in doc.identifiers(ofType: "TST.GroupByArchive") {
                    doc.update(g) { $0.remove("aggregator"); $0.remove("aggregator_ref") }
                }
            }
            try doc.encoded().write(to: Self.dir.appending(path: "old-\(label).numbers"))
        }
        print("SPIKE wrote old-kept / old-stripped")
    }

    /// The `agg_type` sweep, now in the arrangement Numbers actually recomputes: the template's version history,
    /// no cached accumulation, one document per value. What the caption says is what the number means.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesTheAggTypeSweepThatIsRecomputed() throws {
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        guard let oldHistory = templateDoc.blob("Metadata/BuildVersionHistory.plist") else { return }
        for n in 0...12 {
            let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
            doc.setBlob("Metadata/BuildVersionHistory.plist", oldHistory)
            guard let owner = doc.identifiers(ofType: "TST.PivotOwnerArchive").first else { return }
            doc.update(owner) { m in
                guard var list = m.message("aggregate_columns") else { return }
                var aggs = list.messages("aggregates")
                guard !aggs.isEmpty else { return }
                aggs[0].set("agg_type", int: n)
                list.set("aggregates", messages: aggs)
                m.set("aggregate_columns", message: list)
            }
            for g in doc.identifiers(ofType: "TST.GroupByArchive") {
                doc.update(g) { $0.remove("aggregator"); $0.remove("aggregator_ref") }
            }
            try doc.encoded().write(to: Self.dir.appending(path: "aggo-\(String(format: "%02d", n)).numbers"))
        }
        print("SPIKE wrote aggo-00…aggo-12")
    }

    /// The question a writer actually has to answer: given the **rules and the source rows only** — no group
    /// tree, no cached accumulation, as a writer that has never summed anything would leave it — does Numbers
    /// build the pivot? Everything else in the document is the ground truth's, so a difference is this and
    /// nothing else.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesAPivotWithNothingCached() throws {
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        let oldHistory = templateDoc.blob("Metadata/BuildVersionHistory.plist")

        for (label, old) in [("fresh-15", false), ("fresh-old", true)] {
            let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
            if old, let oldHistory { doc.setBlob("Metadata/BuildVersionHistory.plist", oldHistory) }
            guard let ownerID = doc.identifiers(ofType: "TST.PivotOwnerArchive").first else { return }
            // the two table models the pivot is made of, and every group-by they own
            let pivotModel = doc.identifiers(ofType: "TST.TableModelArchive").first { doc.object($0)?.has("pivot_owner") == true }
            let info = doc.identifiers(ofType: "TST.TableInfoArchive").first { doc.object($0)?.bool("is_a_pivot_table") == true }
            let sourceModel = info.flatMap { doc.object($0)?.reference("pivot_data_model") }
            var groupBys: [Int] = []
            for model in [pivotModel, sourceModel].compactMap({ $0 }) {
                guard let ref = doc.object(model)?.reference("category_owner") else { continue }
                groupBys += doc.object(ref)?.references("group_by") ?? []
            }
            print("SPIKE \(label): pivotModel=\(String(describing: pivotModel)) sourceModel=\(String(describing: sourceModel)) groupBys=\(groupBys)")
            for g in groupBys {
                doc.update(g) {
                    $0.remove("aggregator"); $0.remove("aggregator_ref")
                    $0.remove("group_node_root"); $0.remove("group_node_root_ref")
                }
            }
            doc.update(ownerID) { m in
                m.set("refresh_uid", message: NumbersUUID.random().uuid)
                m.set("aggregate_rule_change_uid", message: NumbersUUID.random().uuid)
                m.set("row_column_rule_change_uid", message: NumbersUUID.random().uuid)
            }
            try doc.encoded().write(to: Self.dir.appending(path: "\(label).numbers"))
        }
        print("SPIKE wrote fresh-15 / fresh-old")
    }

    /// Does Numbers believe the group tree, or rebuild it? One label in the cached tree is renamed to a word the
    /// source does not contain — same length, so the bytes can be swapped without touching any framing. If the
    /// document shows `EAST`, the cache is what Numbers draws; if it shows `East`, Numbers rebuilt from source.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesAPivotWhoseCachedLabelIsWrong() throws {
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        let oldHistory = templateDoc.blob("Metadata/BuildVersionHistory.plist")
        for (label, old) in [("liar-15", false), ("liar-old", true)] {
            let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
            if old, let oldHistory { doc.setBlob("Metadata/BuildVersionHistory.plist", oldHistory) }
            var swapped = 0
            for g in doc.identifiers(ofType: "TST.GroupByArchive") {
                guard let obj = doc.object(g) else { continue }
                var bytes = obj.encoded()
                guard let range = bytes.range(of: Data("East".utf8)) else { continue }
                bytes.replaceSubrange(range, with: Data("EAST".utf8))
                guard let rebuilt = try? ProtoMessage(decoding: bytes, typeName: "TST.GroupByArchive") else { continue }
                doc.replace(g, with: rebuilt)
                swapped += 1
            }
            print("SPIKE \(label): swapped \(swapped) group-by archive(s)")
            try doc.encoded().write(to: Self.dir.appending(path: "\(label).numbers"))
        }
    }

    /// Which of the two cached things must be there for Numbers to rebuild the rest: the group tree, or the
    /// aggregators? One document drops each, on the old version stamp that makes Numbers recalculate.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesAPivotMissingOneCachedPartAtATime() throws {
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        guard let oldHistory = templateDoc.blob("Metadata/BuildVersionHistory.plist") else { return }
        for (label, drop) in [("noroot-old", ["group_node_root", "group_node_root_ref"]),
                              ("noagg-old", ["aggregator", "aggregator_ref"]),
                              ("emptyroot-old", ["group_node_root_ref"])] {
            let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
            doc.setBlob("Metadata/BuildVersionHistory.plist", oldHistory)
            guard let info = doc.identifiers(ofType: "TST.TableInfoArchive").first(where: { doc.object($0)?.bool("is_a_pivot_table") == true }),
                  let sourceModel = doc.object(info)?.reference("pivot_data_model"),
                  let pivotModel = doc.object(info)?.reference("tableModel") else { return }
            var groupBys: [Int] = []
            for model in [pivotModel, sourceModel] {
                guard let ref = doc.object(model)?.reference("category_owner") else { continue }
                groupBys += doc.object(ref)?.references("group_by") ?? []
            }
            for g in groupBys { doc.update(g) { m in for f in drop { m.remove(f) } } }
            try doc.encoded().write(to: Self.dir.appending(path: "\(label).numbers"))
            print("SPIKE \(label): dropped \(drop) from \(groupBys)")
        }
    }

    /// The tree has to be there. Does what is *in* it have to be right? One document keeps only the root node —
    /// no children, so none of the source's distinct values is named anywhere — and one keeps only its first
    /// child. If Numbers grows them back, a writer owes it a stump and no grouping of its own.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func writesAPivotWhoseGroupTreeIsAStump() throws {
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        guard let oldHistory = templateDoc.blob("Metadata/BuildVersionHistory.plist") else { return }
        for (label, keepFirstChild) in [("stump-old", false), ("onechild-old", true)] {
            let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
            doc.setBlob("Metadata/BuildVersionHistory.plist", oldHistory)
            guard let info = doc.identifiers(ofType: "TST.TableInfoArchive").first(where: { doc.object($0)?.bool("is_a_pivot_table") == true }),
                  let sourceModel = doc.object(info)?.reference("pivot_data_model"),
                  let pivotModel = doc.object(info)?.reference("tableModel") else { return }
            var groupBys: [Int] = []
            for model in [pivotModel, sourceModel] {
                guard let ref = doc.object(model)?.reference("category_owner") else { continue }
                groupBys += doc.object(ref)?.references("group_by") ?? []
            }
            var pruned = 0
            for g in groupBys {
                doc.update(g) { m in
                    guard var root = m.message("group_node_root") else { return }
                    let children = root.messages("child")
                    guard !children.isEmpty else { return }
                    if keepFirstChild {
                        var first = children[0]
                        first.remove("child")                      // …and no grandchildren either
                        root.set("child", messages: [first])
                    } else {
                        root.remove("child")
                    }
                    m.set("group_node_root", message: root)
                    pruned += 1
                }
                // the separate root object, when the group-by keeps one, would put the children back
                doc.update(g) { $0.remove("group_node_root_ref") }
            }
            try doc.encoded().write(to: Self.dir.appending(path: "\(label).numbers"))
            print("SPIKE \(label): pruned \(pruned) tree(s)")
        }
    }

    /// The corpus the house method needs: **one** workbook, one pivot per sheet, each varying exactly one thing.
    /// Numbers imports it once and writes the answers into archives — what each `agg_type` number means, whether
    /// a rows-only pivot keeps one group-by or two, where a report filter goes, what two values look like. Read
    /// out of the saved document, none of it races a recalculation.
    @Test func writesTheShapeProbeWorkbook() throws {
        var wb = Workbook()
        var data = wb.sheets[0]
        data.name = "Data"
        data.append([.text("Region"), .text("Product"), .text("Qty"), .text("Price")])
        let rows: [(String, String, Int, Double)] = [
            ("East", "A", 5, 1.5), ("West", "B", 7, 2.25), ("North", "A", 3, 4.0), ("East", "B", 4, 2.0),
            ("West", "A", 5, 3.5), ("North", "B", 6, 1.25), ("East", "A", 3, 2.75), ("West", "B", 3, 5.0),
        ]
        for r in rows { data.append([.text(r.0), .text(r.1), .integer(r.2), .number(Decimal(r.3))]) }
        wb.sheets[0] = data
        let source = CellRange("A1:D9")!

        // one sheet per function: the caption Numbers writes names the function, the archive names the number
        let functions: [PivotDataField.Function] = [.sum, .count, .average, .max, .min, .product, .countNums,
                                                    .stdDev, .stdDevp, .var, .varp]
        for f in functions {
            let sheet = "fn-\(f.rawValue)"
            wb.addSheet(named: sheet)
            _ = wb.addPivotTable(named: "P-\(f.rawValue)", to: sheet, at: CellRef("A1")!, summarizing: source, on: "Data",
                                 rows: ["Region"], columns: ["Product"], values: [("Qty", f)])
        }
        // …and one sheet per shape
        wb.addSheet(named: "rows-only")
        _ = wb.addPivotTable(named: "RowsOnly", to: "rows-only", at: CellRef("A1")!, summarizing: source, on: "Data",
                             rows: ["Region"], values: [("Qty", .sum)])
        wb.addSheet(named: "cols-only")
        _ = wb.addPivotTable(named: "ColsOnly", to: "cols-only", at: CellRef("A1")!, summarizing: source, on: "Data",
                             columns: ["Product"], values: [("Qty", .sum)])
        wb.addSheet(named: "two-rows")
        _ = wb.addPivotTable(named: "TwoRows", to: "two-rows", at: CellRef("A1")!, summarizing: source, on: "Data",
                             rows: ["Region", "Product"], values: [("Qty", .sum)])
        wb.addSheet(named: "two-values")
        _ = wb.addPivotTable(named: "TwoValues", to: "two-values", at: CellRef("A1")!, summarizing: source, on: "Data",
                             rows: ["Region"], values: [("Qty", .sum), ("Price", .average)])
        wb.addSheet(named: "filtered")
        _ = wb.addPivotTable(named: "Filtered", to: "filtered", at: CellRef("A1")!, summarizing: source, on: "Data",
                             rows: ["Region"], values: [("Qty", .sum)], filters: ["Product"])
        wb.addSheet(named: "no-totals")
        if var s = wb.sheets["no-totals"] {
            _ = s.addPivotTable(named: "NoTotals", summarizing: source, on: "Data",
                                headerRow: [.text("Region"), .text("Product"), .text("Qty"), .text("Price")],
                                at: CellRef("A1")!, rows: ["Region"], columns: ["Product"], values: [("Qty", .sum)])
            s.pivotTables[0].showRowGrandTotals = false
            s.pivotTables[0].showColumnGrandTotals = false
            wb.sheets["no-totals"] = s
        }
        try wb.write(as: .xlsx).data.write(to: Self.dir.appending(path: "pivot-shapes.xlsx"))
        print("SPIKE wrote pivot-shapes.xlsx with \(wb.sheets.count - 1) pivot sheet(s)")
    }

    /// SPIKE (B.19): the seventeen-pivot probe workbook, written as Numbers. One document, every aggregate
    /// function and every shape the model can ask for, so the judge sweeps them all in one open.
    @Test(.enabled(if: PivotSpikeTests.hasArtifact("pivot-shapes.xlsx"),
                   "pivot-shapes.xlsx has not been written yet — run writesTheShapeProbeWorkbook first"))
    func writesTheShapeProbeWorkbookAsNumbers() throws {
        let xlsx = Self.dir.appending(path: "pivot-shapes.xlsx")
        let wb = try Workbook(data: try Data(contentsOf: xlsx))
        let result = try wb.write(as: .numbers)
        try result.data.write(to: Self.dir.appending(path: "shapes-all.numbers"))
        let doc = try NumbersDocument(data: result.data)
        print("SPIKE shapes-all: \(wb.sheets.count) sheet(s), "
              + "pivot owners \(doc.identifiers(ofType: "TST.PivotOwnerArchive").count), "
              + "integrity \(doc.integrityProblems().count) problem(s)")
    }

    /// The first thing our own writer makes of a pivot: one sheet of rows, one pivot over them.
    @Test func writesAPivotOfOurOwn() throws {
        var wb = Workbook()
        var data = wb.sheets[0]
        data.name = "Data"
        data.append([.text("Region"), .text("Product"), .text("Qty")])
        for r in [("East", "A", 5), ("West", "B", 7), ("North", "A", 3), ("East", "B", 4),
                  ("West", "A", 5), ("North", "B", 6), ("East", "A", 3), ("West", "B", 3)] {
            data.append([.text(r.0), .text(r.1), .integer(r.2)])
        }
        wb.sheets[0] = data
        wb.addSheet(named: "Pivot")
        let added = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: CellRange("A1:C9")!,
                                     on: "Data", rows: ["Region"], columns: ["Product"], values: [("Qty", .sum)])
        #expect(added)
        let result = try wb.write(as: .numbers)
        print("SPIKE warnings: \(result.warnings.map(\.message))")
        try result.data.write(to: Self.dir.appending(path: "ours-pivot.numbers"))
        let doc = try NumbersDocument(data: result.data)
        print("SPIKE integrity: \(doc.integrityProblems())")
        print("SPIKE pivot owners: \(doc.identifiers(ofType: "TST.PivotOwnerArchive")), "
              + "group-bys: \(doc.identifiers(ofType: "TST.GroupByArchive").count)")
        // …and what our own reader makes of it again
        let back = try NumbersCodec.read(result.data).workbook
        print("SPIKE read back sheets: \(back.sheetNames)")
        for s in back.sheets where s.name == "Pivot" {
            for t in s.tables { print("SPIKE   table \(t.name ?? "?") \(t.rowCount)x\(t.columnCount): "
                                      + (0..<t.rowCount).map { r in (0..<t.columnCount).map { c in t[r, c]?.stringValue ?? "_" }.joined(separator: " ") }.joined(separator: " / ")) }
        }
    }

    /// SPIKE (B.19 shape ablation): the same rows, one document per pivot **shape**, so the judge can say which
    /// part of the wiring Numbers refuses. Every session so far measured the hardest shape only — two group-bys,
    /// a nested column tree and both total lanes. A shape that draws puts a floor under the defect.
    @Test func writesOneDocumentPerPivotShape() throws {
        func base() -> Workbook {
            var wb = Workbook()
            var data = wb.sheets[0]
            data.name = "Data"
            data.append([.text("Region"), .text("Product"), .text("Qty")])
            for r in [("East", "A", 5), ("West", "B", 7), ("North", "A", 3), ("East", "B", 4),
                      ("West", "A", 5), ("North", "B", 6), ("East", "A", 3), ("West", "B", 3)] {
                data.append([.text(r.0), .text(r.1), .integer(r.2)])
            }
            wb.sheets[0] = data
            wb.addSheet(named: "Pivot")
            return wb
        }
        let source = CellRange("A1:C9")!
        let header: [CellValue] = [.text("Region"), .text("Product"), .text("Qty")]

        // rows and columns, but no grand-total lanes at all
        var noTotals = base()
        if var s = noTotals.sheets["Pivot"] {
            _ = s.addPivotTable(named: "Summary", summarizing: source, on: "Data", headerRow: header,
                                at: CellRef("A1")!, rows: ["Region"], columns: ["Product"], values: [("Qty", .sum)])
            s.pivotTables[0].showRowGrandTotals = false
            s.pivotTables[0].showColumnGrandTotals = false
            noTotals.sheets["Pivot"] = s
        }
        // one axis only: a single group-by, no nested tree
        var rowsOnly = base()
        _ = rowsOnly.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: source,
                                   on: "Data", rows: ["Region"], values: [("Qty", .sum)])
        var colsOnly = base()
        _ = colsOnly.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: source,
                                   on: "Data", columns: ["Product"], values: [("Qty", .sum)])

        for (label, wb) in [("shape-nototals", noTotals), ("shape-rowsonly", rowsOnly), ("shape-colsonly", colsOnly)] {
            let result = try wb.write(as: .numbers)
            try result.data.write(to: Self.dir.appending(path: "\(label).numbers"))
            let doc = try NumbersDocument(data: result.data)
            print("SPIKE \(label): integrity \(doc.integrityProblems().count) problem(s), "
                  + "group-bys \(doc.identifiers(ofType: "TST.GroupByArchive").count), "
                  + "warnings \(result.warnings.map(\.message))")
            let back = try NumbersCodec.read(result.data).workbook
            for s in back.sheets where s.name == "Pivot" {
                for t in s.tables where t.rowCount > 0 {
                    print("SPIKE \(label)   \(t.name ?? "?") \(t.rowCount)x\(t.columnCount): "
                          + (0..<t.rowCount).map { r in (0..<t.columnCount).map { c in t[r, c]?.stringValue ?? "_" }.joined(separator: " ") }.joined(separator: " / "))
                }
            }
        }
    }

    /// Is our group tree the thing Numbers cannot read, or is the scaffolding around it? This puts **our** tree
    /// into the document that works — the trees name no column, only values and row numbers, so they transplant —
    /// and asks. If the ground truth still computes, the tree is sound and the fault is everything else.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"),
          .enabled(if: PivotSpikeTests.hasArtifact("ours-pivot.numbers"),
                   "ours-pivot.numbers has not been written yet — run writesAPivotOfOurOwn first"))
    func transplantsOurTreeIntoTheDocumentThatWorks() throws {
        let ours = Self.dir.appending(path: "ours-pivot.numbers")
        let ourDoc = try NumbersDocument(data: try Data(contentsOf: ours))
        var ourRoots: [ProtoMessage] = []
        for g in ourDoc.identifiers(ofType: "TST.GroupByArchive") {
            guard let m = ourDoc.object(g), !m.messages("group_column").isEmpty, let root = m.message("group_node_root") else { continue }
            ourRoots.append(root)
        }
        print("SPIKE our trees: \(ourRoots.count)")

        let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
        // the template's version history, so Numbers recalculates instead of believing a cache we just removed
        let templateDoc = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        if let old = templateDoc.blob("Metadata/BuildVersionHistory.plist") {
            doc.setBlob("Metadata/BuildVersionHistory.plist", old)
        }
        guard let info = doc.identifiers(ofType: "TST.TableInfoArchive").first(where: { doc.object($0)?.bool("is_a_pivot_table") == true }),
              let sourceModel = doc.object(info)?.reference("pivot_data_model"),
              let cat = doc.object(sourceModel)?.reference("category_owner") else { return }
        let groupBys = doc.object(cat)?.references("group_by") ?? []
        for (i, g) in groupBys.enumerated() where i < ourRoots.count {
            // the cached aggregators name the *old* tree's coordinates, so they have to go with it — otherwise
            // this measures a coordinate mismatch rather than the tree
            doc.update(g) {
                $0.set("group_node_root", message: ourRoots[i])
                $0.remove("group_node_root_ref"); $0.remove("aggregator"); $0.remove("aggregator_ref")
            }
        }
        try doc.encoded().write(to: Self.dir.appending(path: "transplant.numbers"))
        print("SPIKE transplanted \(Swift.min(groupBys.count, ourRoots.count)) tree(s) into the ground truth")
    }

    /// The control the transplant needs: the ground truth's **own** tree, taken out and put straight back through
    /// the same re-encoding. If this breaks too, the fault is in how we write a tree, not in what is in ours.
    @Test(.enabled(if: PivotSpikeTests.hasGround, "the Numbers ground truth is not at \(PivotSpikeTests.ground.path)"))
    func transplantsTheGroundTruthsOwnTreeBackIntoItself() throws {
        let doc = try NumbersDocument(data: try Data(contentsOf: Self.ground))
        guard let info = doc.identifiers(ofType: "TST.TableInfoArchive").first(where: { doc.object($0)?.bool("is_a_pivot_table") == true }),
              let sourceModel = doc.object(info)?.reference("pivot_data_model"),
              let cat = doc.object(sourceModel)?.reference("category_owner") else { return }
        for g in doc.object(cat)?.references("group_by") ?? [] {
            guard let root = doc.object(g)?.message("group_node_root") else { continue }
            doc.update(g) {
                $0.set("group_node_root", message: root)
                $0.remove("group_node_root_ref"); $0.remove("aggregator"); $0.remove("aggregator_ref")
            }
        }
        try doc.encoded().write(to: Self.dir.appending(path: "control.numbers"))
        print("SPIKE wrote control.numbers")
    }
}
