import Foundation
import Testing
import SheetEncrypt

/// The password forms take `format:` as the plain ones do (spec Appendix B.107).
struct PasswordFormatTests {
    @Test func aProtectedFileOpensAsTheNamedFormat() throws {
        let workbook = try Workbook(data: Data("x\n1\n".utf8), format: .csv)
        // an extension that names no format: only the argument, or the bytes, can say what the file is
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try workbook.write(to: destination, as: .xlsx, password: "fixture")
        #expect(try Workbook.read(contentsOf: destination, password: "fixture", format: .xlsx).workbook.sheets[0]["A1"] == "x")
        #expect(try Workbook(contentsOf: destination, password: "fixture", format: nil).sheets[0]["A1"] == "x")
        #expect(try Workbook.inspect(contentsOf: destination, password: "fixture", format: .xlsx).sheets.count == 1)
    }
}
