import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// The quote functions — STOCK, STOCKH and the CURRENCY family — whose answers come from Apple's quote service,
/// not from the sheet. `stock-15.numbers` is a document Numbers 15.3.1 built itself: the owner's hand-made
/// STOCK cell, extended over AppleScript with every attribute shape (number, none, a string — which Numbers
/// itself answers with an error), STOCKH, and headings. Reading keeps the formula with the fetched value as its
/// cache; a same-format write keeps the formula for Numbers to fetch anew; Excel and ODS have no spelling for
/// any of the six, so those writers put the fetched value in the formula's place and say so — which is exactly
/// what Numbers' own Excel export does (measured on 15.3.1: STOCK flattened, `=E2*2+1` beside it kept).
@Suite struct NumbersStockTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/\(name)"))
    }

    // MARK: - Reading Numbers' own document

    @Test func aStockFormulaKeepsItsShapeAndItsFetchedValue() throws {
        let result = try NumbersCodec.read(try Self.fixture("stock-15.numbers"))
        let s = result.workbook.sheets[0]
        #expect(s["C2"]?.formula == .call(name: "STOCK", args: [.string("AAPL"), .number(0)]))
        #expect(s["C2"]?.cachedValue?.doubleValue == 313.45)
        // attribute 1 is the company name: the cache is a string
        #expect(s["C3"]?.cachedValue?.textValue == "Apple Inc.")
        // no attribute at all
        #expect(s["C6"]?.formula == .call(name: "STOCK", args: [.string("AAPL")]))
        // STOCKH takes a date, spelt as a nested DATE call
        #expect(s["C7"]?.formula == .call(name: "STOCKH", args: [.string("AAPL"), .number(0),
                                                                 .call(name: "DATE", args: [.number(2026), .number(8), .number(20)])]))
        #expect(result.warnings.isEmpty, Comment(rawValue: "\(result.warnings.map(\.message))"))
    }

    /// `STOCK("AAPL","name")` is a shape Numbers accepts and then answers with an error — the attribute must be
    /// a number. The error is what the document holds, so the error is what the cache says.
    @Test func aStockErrorIsCachedAsTheError() throws {
        let wb = try Workbook(data: try Self.fixture("stock-15.numbers"), format: .numbers)
        let cell = wb.sheets[0]["C8"]
        #expect(cell?.formula == .call(name: "STOCK", args: [.string("AAPL"), .string("name")]))
        #expect(cell?.cachedValue?.errorValue == "#VALUE!")
    }

    // MARK: - Writing

    /// Numbers is the one format that can recompute a quote, so the formula goes back as a formula.
    /// (Judged by Numbers itself on 2026-08-27: every one came back `=STOCK(…)` with a freshly fetched value.)
    @Test func aSameFormatWriteKeepsTheQuoteFormulas() throws {
        let wb = try Workbook(data: try Self.fixture("stock-15.numbers"), format: .numbers)
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.filter { $0.subject == .formulas }.isEmpty,
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try Workbook(data: result.data)
        let s = back.sheets[0]
        #expect(s["C2"]?.formula == .call(name: "STOCK", args: [.string("AAPL"), .number(0)]))
        #expect(s["C7"]?.formula?.remoteDataFunction == "STOCKH")
    }

    /// Excel and OpenFormula have no STOCK: the fetched value is written in its place, out loud — the mapping
    /// Numbers itself applies when it exports to Excel.
    @Test(arguments: [SheetFormat.xlsx, .ods])
    func theOtherFormatsGetTheValueAndTheReason(_ format: SheetFormat) throws {
        let wb = try Workbook(data: try Self.fixture("stock-15.numbers"), format: .numbers)
        let result = try wb.write(as: format)
        let flattened = result.warnings.filter { $0.kind == .degraded && $0.message.contains("fetches live data") }
        #expect(flattened.count == 8, Comment(rawValue: "\(format.rawValue): \(result.warnings.map(\.message))"))
        #expect(flattened.contains { $0.message.hasPrefix("STOCK ") })
        #expect(flattened.contains { $0.message.hasPrefix("STOCKH ") })
        let back = try Workbook(data: result.data)
        let s = back.sheets[0]
        #expect(s["C2"]?.formula == nil)
        #expect(s["C2"]?.doubleValue == 313.45)
        #expect(s["C3"]?.textValue == "Apple Inc.")
    }

    /// The whole family flattens, not just the two in the fixture — a CURRENCY call built through the API
    /// meets the same mapping.
    @Test func theCurrencyFamilyFlattensToo() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = .formula(FormulaExpr.parse("CURRENCY(\"USD\",\"JPY\")"), cached: .number(159.498))
        wb.sheets[0]["A2"] = .formula(FormulaExpr.parse("B1+CURRENCYCONVERT(100,\"USD\",\"JPY\")"), cached: nil)
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.message.hasPrefix("CURRENCY ") })
        #expect(result.warnings.contains { $0.message.hasPrefix("CURRENCYCONVERT ") })
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0]["A1"]?.formula == nil)
        #expect(back.sheets[0]["A1"]?.doubleValue == 159.498)
        // no cache to fall back on: the cell goes out empty rather than wrong
        #expect(back.sheets[0]["A2"] == nil)
    }
}
