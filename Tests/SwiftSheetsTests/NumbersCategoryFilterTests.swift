import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// The three readers unblocked by the owner's hand-made documents (spec Appendix B.29): a category grouping, a
/// table filter, and a stock-quote cell — each a Numbers 15.3.1 document built in the application's own UI,
/// because AppleScript has no vocabulary for any of the three.
///
/// What each comes back as was decided by Numbers' own Excel export, measured on the same documents:
/// * A **filter** loses its rules even there; only the hidden rows travel. So the reader keeps the hidden rows
///   and drops the rules out loud.
/// * A **category grouping** is baked into the export as extra label rows and a shifted grid — a change of data
///   this library does not copy. The rows stay flat, and the grouping is dropped out loud, named by its columns.
/// * A **stock-quote cell** turns out to be no special cell at all in current Numbers: Insert ▸ Stock Quote
///   writes a plain `STOCK` formula, which Appendix B.27 already carries. The quote *table* variant adds
///   attribute pop-up menus on its header cells, dropped out loud as on any second table.
@Suite struct NumbersCategoryFilterTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/\(name)"))
    }

    @Test func aCategoryGroupingIsDroppedOutLoudAndTheRowsStayFlat() throws {
        let result = try NumbersCodec.read(try Self.fixture("category-15.numbers"))
        let s = result.workbook.sheets[0]
        // the rows come back flat, in stored order, ungarbled
        #expect(s["A1"]?.textValue == "No.")
        #expect(s["B2"]?.textValue == "関西")
        #expect(s["D6"]?.textValue == "神奈川事業所")
        // …and the grouping is named, with the columns it grouped by
        let named = result.warnings.filter { $0.message.contains("category grouping") }
        #expect(named.count == 1, Comment(rawValue: "\(result.warnings.map(\.message))"))
        #expect(named.first?.kind == .degraded)
        #expect(named.first?.message.contains("地域") == true)
        #expect(named.first?.message.contains("都道府県") == true)
    }

    @Test func aFilterKeepsItsEffectAndNamesItsLoss() throws {
        let result = try NumbersCodec.read(try Self.fixture("filter-15.numbers"))
        let table = result.workbook.sheets[0].tables[0]
        // the rows the filter hides come back hidden — the same rows Numbers' own Excel export hides
        // (data rows 1–4, 6 and 8; rows 5 and 7 — 東京本社 and 恵比寿事業所 — stay visible)
        for hidden in [1, 2, 3, 4, 6, 8] { #expect(table.rowDimensions[hidden]?.hidden == true, "row \(hidden)") }
        for visible in [0, 5, 7] { #expect(table.rowDimensions[visible]?.hidden != true, "row \(visible)") }
        // …and the rules are dropped out loud, counted
        let named = result.warnings.filter { $0.message.contains("Numbers filter") }
        #expect(named.count == 1, Comment(rawValue: "\(result.warnings.map(\.message))"))
        #expect(named.first?.kind == .degraded)
        #expect(named.first?.message.contains("2 rule(s)") == true)
    }

    /// The hidden rows survive the trip out: to Excel the same way Numbers itself exports the file, and back
    /// into Numbers as ordinary hidden rows.
    @Test(arguments: [SheetFormat.xlsx, .numbers])
    func theFiltersEffectSurvivesTheTrip(_ format: SheetFormat) throws {
        let wb = try Workbook(data: try Self.fixture("filter-15.numbers"), format: .numbers)
        let back = try Workbook(data: try wb.write(as: format).data)
        let table = back.sheets[0].tables[0]
        #expect(table.rowDimensions[1]?.hidden == true)
        #expect(table.rowDimensions[6]?.hidden == true)
        #expect(table.rowDimensions[5]?.hidden != true)
    }

    /// The same document with its filter switched **off** (the owner's second hand-made specimen): Numbers
    /// empties the hidden-state list — so nothing is hidden, exactly as the safe reading assumed — and keeps the
    /// two rules in their off state, which the model cannot hold and drops out loud. Numbers' own Excel export
    /// of the same document shows every row and carries no filter either (measured).
    @Test func aSwitchedOffFilterHidesNothingAndItsRulesAreDroppedOutLoud() throws {
        let result = try NumbersCodec.read(try Self.fixture("filter-off-15.numbers"))
        let table = result.workbook.sheets[0].tables[0]
        for row in 0...8 { #expect(table.rowDimensions[row]?.hidden != true, "row \(row)") }
        let named = result.warnings.filter { $0.message.contains("switched-off Numbers filter") }
        #expect(named.count == 1, Comment(rawValue: "\(result.warnings.map(\.message))"))
        #expect(named.first?.kind == .dropped)
        #expect(named.first?.message.contains("2 rule(s)") == true)
        // …and no live-filter warning fires alongside it
        #expect(!result.warnings.contains { $0.message.contains("a Numbers filter (") })
    }

    /// The same document with its categories switched **off** (another hand-made specimen): the flip is
    /// `is_enabled` alone — the grouped columns and the whole tree stay — and Numbers' own Excel export of it
    /// carries no trace of the grouping (measured: a flat table, no label rows, no shifted grid). The retained
    /// set-up has no place in the model and is dropped out loud, named by its columns.
    @Test func switchedOffCategoriesAreDroppedOutLoud() throws {
        let result = try NumbersCodec.read(try Self.fixture("category-off-15.numbers"))
        let s = result.workbook.sheets[0]
        #expect(s["D6"]?.textValue == "神奈川事業所")     // the rows still come back flat and whole
        let named = result.warnings.filter { $0.message.contains("switched-off category grouping") }
        #expect(named.count == 1, Comment(rawValue: "\(result.warnings.map(\.message))"))
        #expect(named.first?.kind == .dropped)
        #expect(named.first?.message.contains("地域") == true)
        #expect(named.first?.message.contains("都道府県") == true)
        #expect(!result.warnings.contains { $0.message.contains("a category grouping by") })
    }

    /// A sort order (another hand-made specimen; the Sort panel has no on/off switch, confirmed in the UI):
    /// applying it reorders the stored rows themselves, so the data comes back already sorted — and the rules,
    /// which only Numbers could use again, are dropped out loud. Numbers' own Excel export of the same document
    /// carries no sortState element either (measured): the sorted rows are the whole story there too.
    @Test func aSortOrderKeepsTheOrderAndNamesItsRules() throws {
        let result = try NumbersCodec.read(try Self.fixture("sort-15.numbers"))
        let table = result.workbook.sheets[0].tables[0]
        // the stored rows are the sorted rows: No. runs 8 down to 1
        #expect(table[1, 0]?.intValue == 8)
        #expect(table[8, 0]?.intValue == 1)
        let named = result.warnings.filter { $0.message.contains("Numbers sort order") }
        #expect(named.count == 1, Comment(rawValue: "\(result.warnings.map(\.message))"))
        #expect(named.first?.kind == .degraded)
        #expect(named.first?.message.contains("2 rule(s)") == true)
        #expect(named.first?.message.contains("No.") == true)
        #expect(named.first?.message.contains("事業所") == true)
    }

    /// The discriminator the category warning stands on: a pivot summary's own group-by names no columns, so a
    /// pivot document must not be mistaken for a categorised table.
    @Test func aPivotIsNotMistakenForACategoryGrouping() throws {
        let result = try NumbersCodec.read(try Self.fixture("pivot-mixed-15.numbers"))
        #expect(!result.warnings.contains { $0.message.contains("category grouping") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
    }

    @Test func aStockQuoteCellIsAStockFormula() throws {
        let result = try NumbersCodec.read(try Self.fixture("stockcell-15.numbers"))
        let s = result.workbook.sheets[0]
        // Insert ▸ Stock Quote on a cell: a plain STOCK formula with the fetched value cached
        #expect(s.tables[0]["B2"]?.formula == .call(name: "STOCK", args: [.string("AAPL"), .number(0)]))
        #expect(s.tables[0]["B2"]?.cachedValue?.doubleValue == 313.45)
        // the quote-table variant: STOCK by cell reference under attribute headings
        #expect(s.tables[1]["B1"]?.textValue == "名称")
        #expect(s.tables[1]["B2"]?.cachedValue?.textValue == "Apple Inc.")
        #expect(s.tables[1]["B2"]?.formula?.remoteDataFunction == "STOCK")
        // its attribute pop-up menus sit on a second table, and the loss is named
        #expect(result.warnings.contains { $0.message.contains("pop-up menus on a second table") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        // nothing here claims a control the model has no word for — the old "stock quote" warning stays silent
        #expect(!result.warnings.contains { $0.message.contains("no word for") })
    }
}
