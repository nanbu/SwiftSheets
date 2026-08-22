// swift-tools-version: 6.2
import PackageDescription

// SwiftSheets — a pure Swift spreadsheet library with one format-neutral model (SheetCore) and one codec per file
// format. Foundation + the Compression framework only; no external dependencies.
//
//   SheetCore   model, styles, formula AST, codec contract, ZIP / XML plumbing, CSV options   (no dependencies)
//   SheetXLSX   .xlsx / .xlsm codec (ECMA-376 SpreadsheetML) with round-trip preservation
//   SheetCSV    .csv / .tsv codec (RFC 4180 + real-world dialects, explicit encodings)
//   SwiftSheets everything, plus the facade: Workbook(contentsOf:), write(to:as:), convert
//
// Import only what you need (`import SheetXLSX`) or the umbrella (`import SwiftSheets`).
let package = Package(
    name: "SwiftSheets",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SheetCore", targets: ["SheetCore"]),
        .library(name: "SheetXLSX", targets: ["SheetXLSX"]),
        .library(name: "SheetCSV", targets: ["SheetCSV"]),
        .library(name: "SwiftSheets", targets: ["SwiftSheets"])
    ],
    targets: [
        .target(name: "SheetCore"),
        .target(name: "SheetXLSX", dependencies: ["SheetCore"]),
        .target(name: "SheetCSV", dependencies: ["SheetCore"]),
        .target(name: "SwiftSheets", dependencies: ["SheetCore", "SheetXLSX", "SheetCSV"]),
        .testTarget(
            name: "SwiftSheetsTests",
            dependencies: ["SwiftSheets"],
            resources: [.copy("Fixtures")]
        )
    ]
)
