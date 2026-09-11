// # Convert every Excel file in a folder to ODS, with a log of what each conversion lost
//
// `Workbook.convert` reads, writes and answers with the warnings of both halves. What ODS cannot express — a
// feature Excel alone has — is reported per file, never dropped in silence.
import Foundation
import SwiftSheets

func convertAFolder(in directory: URL) throws {
    let input = directory.appending(path: "incoming")
    let output = directory.appending(path: "converted")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for name in ["january", "february"] { try makeSampleWorkbook(at: input.appending(path: "\(name).xlsx")) }

    var log: [String] = []
    let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "xlsx" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in files {
        let target = output.appending(path: file.deletingPathExtension().lastPathComponent + ".ods")
        let result = try Workbook.convert(file, to: target, as: .ods)   // the format is always named
        log.append("\(file.lastPathComponent) → \(target.lastPathComponent): \(result.warnings.count) warning(s)")
        for warning in result.warnings { log.append("  \(warning)") }
    }
    try log.joined(separator: "\n").write(to: output.appending(path: "conversion.log"), atomically: true, encoding: .utf8)
    print(log.joined(separator: "\n"))
}
