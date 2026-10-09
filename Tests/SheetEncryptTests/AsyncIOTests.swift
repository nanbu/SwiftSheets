import Foundation
import Testing
import SheetEncrypt

struct AsyncIOTests {
    @Test func protectedURLFormatAndAsyncRoundTrip() async throws {
        let workbook = try Workbook(data: Data("x\n1\n".utf8), format: .csv)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try await workbook.write(to: destination, as: .xlsx, password: "fixture")
        #expect(!result.data.isEmpty)
        let read = try await Workbook.read(contentsOf: destination, password: "fixture", format: .xlsx)
        #expect(read.workbook.sheets.count == workbook.sheets.count)
        _ = try await Workbook.inspect(contentsOf: destination, password: "fixture", format: .xlsx)
    }
}
