import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// The crossings a table's own lists make into the stylesheet (spec Appendix B.37).
///
/// Numbers follows a reference into another component through the package metadata, so a crossing the metadata
/// does not declare is one it cannot follow — and it refuses the document without saying why. Every other reader
/// in this project follows the reference directly and never notices, which is how this survived: numbers-parser,
/// LibreOffice and our own reader all read the broken document happily.
///
/// The loss had one cause. A **copied** sheet's component is only queued while that sheet is being written
/// (`flushComponents` runs once, at the end), so `componentID(forObject:)` answered nil for it and the
/// registration was skipped altogether. The first sheet is patched into the template, whose component already
/// exists — which is why a style on sheet 1 was fine and the same style on sheet 2 was not.
@Suite struct NumbersCrossingTests {
    /// Style objects a table's style list names that live in another component without the metadata saying so.
    static func undeclaredStyleCrossings(_ data: Data) throws -> [String] {
        let doc = try NumbersDocument(data: data)
        var declared: [Int: Set<Int>] = [:]
        for c in doc.object(NumbersDocument.packageID)?.messages("components") ?? [] {
            guard let id = c.int("identifier") else { continue }
            declared[id] = Set(c.messages("external_references").compactMap { $0.int("object_identifier") })
        }
        var out: [String] = []
        for tid in doc.identifiers(ofType: "TST.TableModelArchive") {
            guard let model = doc.object(tid),
                  let listID = model.message("base_data_store")?.reference("styleTable"),
                  let list = doc.object(listID), let from = doc.componentID(forObject: listID) else { continue }
            for object in list.messages("entries").compactMap({ $0.reference("reference") }) {
                guard let to = doc.componentID(forObject: object), to != from else { continue }
                if declared[from]?.contains(object) != true {
                    out.append("\(model.string("table_name") ?? "?"): \(object) in component \(to) undeclared by \(from)")
                }
            }
        }
        return out
    }

    static func twoSheets(styleFirst: Bool, styleSecond: Bool) -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "One"; wb.sheets[0]["A1"] = "first"
        wb.addSheet(named: "Two"); wb.sheets[1]["A1"] = "second"
        if styleFirst { wb.sheets[0].style("A1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "DDEBF7")) } }
        if styleSecond { wb.sheets[1].style("A1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "FFC7CE")) } }
        return wb
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func aStyleOnAnySheetDeclaresItsCrossing(_ style: (first: Bool, second: Bool)) throws {
        let data = try Self.twoSheets(styleFirst: style.first, styleSecond: style.second).write(as: .numbers).data
        let undeclared = try Self.undeclaredStyleCrossings(data)
        #expect(undeclared.isEmpty, Comment(rawValue: "\(undeclared)"))
        let problems = try NumbersDocument(data: data).integrityProblems()
        #expect(problems.isEmpty, Comment(rawValue: "\(problems.prefix(3))"))
    }

    /// The shape that found this: several sheets, every one of them formatted.
    @Test func everySheetOfAManySheetWorkbookDeclaresItsCrossings() throws {
        var wb = Workbook()
        wb.sheets[0].name = "S1"
        for i in 1..<5 { wb.addSheet(named: "S\(i + 1)") }
        for i in 0..<5 {
            wb.sheets[i]["A1"] = .text("sheet \(i + 1)")
            wb.sheets[i].style("A1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "FFC7CE")) }
            wb.sheets[i]["B1"] = .number(Decimal(string: "1234.5")!)
            wb.sheets[i].style("B1") { $0.numberFormat = "#,##0.00" }
        }
        let result = try wb.write(as: .numbers)
        let undeclared = try Self.undeclaredStyleCrossings(result.data)
        #expect(undeclared.isEmpty, Comment(rawValue: "\(undeclared.prefix(4))"))
        #expect(!result.warnings.contains { $0.message.contains("cross-component reference") })
        // and the values are still there after the round trip
        let back = try Workbook(data: result.data)
        #expect(back.sheetNames == ["S1", "S2", "S3", "S4", "S5"])
        #expect(back.sheets[4]["A1"] == .text("sheet 5"))
        #expect(back.sheets[4].style("A1").font.bold)
    }
}
