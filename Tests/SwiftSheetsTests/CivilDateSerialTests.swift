import Foundation
import Testing
@testable import SheetCore

/// `CivilDate(serial:epoch:)` is the day `CellValue(serial:epoch:)` gives, and nil where that is not a date (spec
/// Appendix B.92).
@Suite struct CivilDateSerialTests {
    @Test(arguments: [1.0, 59, 60, 61, 366, 45_000.75, -5.25, 2_958_465.9999999])
    func theDayIsTheOneACellValueGives(_ serial: Double) {
        for epoch in [DateEpoch.windows1900, .mac1904] {
            let day = CivilDate(serial: serial, epoch: epoch)
            #expect(day != nil, "\(serial) in \(epoch)")
            #expect(day == CellValue(serial: serial, epoch: epoch)?.dateValue?.date, "\(serial) in \(epoch)")
        }
    }

    /// Around Lotus's phantom 1900-02-29: 59 and 60 are both the 28th and 61 is the first of March, as openpyxl's
    /// `from_excel` gives them.
    @Test func thePhantomLeapDay() {
        #expect(CivilDate(serial: 59) == CivilDate(iso8601: "1900-02-28"))
        #expect(CivilDate(serial: 60) == CivilDate(iso8601: "1900-02-28"))
        #expect(CivilDate(serial: 61) == CivilDate(iso8601: "1900-03-01"))
        #expect(CivilDate(serial: 1, epoch: .mac1904) == CivilDate(iso8601: "1904-01-02"))
    }

    @Test(arguments: [0.0, 0.5, .nan, .infinity, -.infinity])
    func aSerialThatIsNotADayIsNil(_ serial: Double) {
        #expect(CivilDate(serial: serial) == nil)
        #expect(CivilDate(serial: serial, epoch: .mac1904) == nil)
    }
}
