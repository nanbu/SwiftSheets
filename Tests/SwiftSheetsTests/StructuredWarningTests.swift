import Foundation
import Testing
import SwiftSheets

@Suite struct StructuredWarningTests {
    @Test func theLegacyInitializerAndDescriptionStayCompatible() {
        let make: (ConversionWarning.Kind, ConversionWarning.Subject, String?, CellRef?, String) -> ConversionWarning =
            ConversionWarning.init(_:subject:sheet:location:message:)
        let warning = make(.degraded, .objects, "Plan", CellRef("B2"), "simplified")
        #expect(warning.context == nil)
        #expect(warning.description == "Plan!B2: simplified")
    }

    @Test func contextIsIndependentOfMessageAndWarningKind() {
        let context = ConversionWarning.Context(code: .drawingUnmodelled, part: "xl/drawings/drawing1.xml",
                                                object: "Group 1", preservation: .preserved)
        let warning = ConversionWarning(.degraded, subject: .objects, sheet: "Plan", context: context,
                                        message: "source XML retained")
        #expect(warning.context?.code == .drawingUnmodelled)
        #expect(warning.context?.preservation == .preserved)
        #expect(warning.context?.object == "Group 1")
        #expect(warning.description == "Plan: source XML retained")
        #expect(ConversionWarning.Code(rawValue: "future.cause").rawValue == "future.cause")
        #expect(warning != ConversionWarning(.degraded, subject: .objects, sheet: "Plan", message: warning.message))
    }

    @Test func resultsRetainStructuredContext() {
        let warning = ConversionWarning(.dropped, subject: .objects,
                                        context: .init(code: .drawingRebuilt, preservation: .notPreserved),
                                        message: "drawing was rebuilt")
        let read = ReadResult(workbook: Workbook(), warnings: [warning])
        #expect(read.workbook.readWarnings == [warning])
        #expect(read.warnings.first?.context?.code == .drawingRebuilt)
        let write = WriteResult(data: Data(), warnings: read.warnings)
        #expect(write.warnings.first?.context?.preservation == .notPreserved)
    }
}
