import Testing
import Foundation
@testable import SwiftSheets

/// A list rule can be built from the choices themselves, and read back as them, without the caller knowing how the
/// file spells an inline list (spec Appendix B.55).
struct DataValidationChoicesTests {
    private let cells = MultiCellRange("A2:A9")!

    @Test func choicesBecomeTheInlineListAndComeBack() throws {
        let rule = try #require(DataValidation.list(choices: ["Todo", "Doing", "Done"], over: cells))
        #expect(rule.kind == .list && rule.formula1 == "\"Todo,Doing,Done\"")
        #expect(rule.listChoices == ["Todo", "Doing", "Done"])
        #expect(rule.allowBlank && !rule.showErrorMessage, "the same suggest-by-default as list(_:over:)")
        let strict = try #require(DataValidation.list(choices: ["a"], over: cells, allowBlank: false, rejects: true))
        #expect(!strict.allowBlank && strict.showErrorMessage && strict.errorStyle == .stop)
    }

    @Test func whatCannotBeAnInlineListIsNil() {
        #expect(DataValidation.list(choices: ["a,b", "c"], over: cells) == nil, "a comma is the separator")
        #expect(DataValidation.list(choices: ["say \"hi\""], over: cells) == nil, "a quote closes the list")
        #expect(DataValidation.list(choices: [], over: cells) == nil, "no choices is not a list")
        let long = Array(repeating: "abcd", count: 60)                                 // 4 × 60 + 59 commas = 299
        #expect(DataValidation.list(choices: long, over: cells) == nil, "past the format's limit")
        let atLimit = Array(repeating: "abcd", count: 51)                              // 4 × 51 + 50 = 254
        #expect(DataValidation.list(choices: atLimit, over: cells) != nil)
    }

    @Test func aRangeSourcedListHasNoChoicesToGive() {
        #expect(DataValidation.list("'Choices'!$A$2:$A$4", over: cells).listChoices == nil)
        #expect(DataValidation(kind: .whole, ranges: cells, formula1: "1").listChoices == nil)
        #expect(DataValidation.list("\"a,,b\"", over: cells).listChoices == ["a", "", "b"], "an empty item is an item")
    }

    @Test(arguments: [SheetFormat.xlsx, .ods])
    func theChoicesSurviveTheFile(_ format: SheetFormat) throws {
        var wb = Workbook()
        wb.sheets[0].dataValidations = [DataValidation.list(choices: ["赤", "青", "yellow"], over: cells)!]
        let back = try Workbook(data: try wb.write(as: format).data)
        #expect(back.sheets[0].dataValidations.first?.listChoices == ["赤", "青", "yellow"], "\(format)")
    }
}
