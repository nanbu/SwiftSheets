// swift-tools-version: 6.2
import PackageDescription

// SwiftSheets — a pure Swift spreadsheet library with one format-neutral model (SheetCore) and one codec per file
// format. Foundation only; no package dependencies. Bytes are folded by whichever DEFLATE the machine already has —
// Apple's Compression framework where it exists, the system zlib otherwise (CZlib below maps the header, it resolves
// nothing).
//
//   SheetCore   model, styles, formula AST, codec contract, ZIP / XML plumbing, CSV options   (no dependencies)
//   SheetXLSX   .xlsx / .xlsm codec (ECMA-376 SpreadsheetML) with round-trip preservation
//   SheetCSV    .csv / .tsv codec (RFC 4180 + real-world dialects, explicit encodings)
//   SheetODS    .ods codec (ODF 1.3 OpenDocument Spreadsheet)
//   SheetNumbers .numbers codec (Apple iWork IWA: Snappy + Protobuf, schema from numbers-parser — see NOTICE)
//   SwiftSheets everything, plus the facade: Workbook(contentsOf:), write(to:as:), convert
//
// None of the above contains encryption code: a protected file is recognised and refused by name. Opening one
// is a separate product, and protecting one another, so that an app declares what it links (spec Appendix B.39.9):
//
//   SheetDecrypt decrypt(_:password:) and Workbook(contentsOf:password:) — AES's inverse cipher, key derivation,
//                the compound file's reader, the OOXML / ODF package forms opened. No encryption (writing) code.
//   SheetEncrypt encrypt(_:as:password:) and write(to:password:) — the cipher, salts, the compound file written.
//                Depends on SheetDecrypt and re-exports it.
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
        .library(name: "SheetODS", targets: ["SheetODS"]),
        .library(name: "SheetNumbers", targets: ["SheetNumbers"]),
        .library(name: "SwiftSheets", targets: ["SwiftSheets"]),
        .library(name: "SheetDecrypt", targets: ["SheetDecrypt"]),
        .library(name: "SheetEncrypt", targets: ["SheetEncrypt"])
    ],
    targets: [
        // Not a dependency in the SwiftPM sense: zlib ships with every Apple SDK and every Linux distribution, and
        // this target is a module map over the header that is already there. It is what `Deflate` falls back to
        // where Apple's Compression framework does not exist.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "SheetCore", dependencies: ["CZlib"]),
        .target(name: "SheetXLSX", dependencies: ["SheetCore"]),
        .target(name: "SheetCSV", dependencies: ["SheetCore"]),
        .target(name: "SheetODS", dependencies: ["SheetCore"]),
        // `.process`, not `.copy`: a copied directory keeps its name inside the bundle, and a folder literally
        // named "Resources" at the root of a flat (iOS) bundle makes codesign read it as a malformed
        // versioned bundle — "bundle format unrecognized, invalid, or unsuitable". Processing flattens the
        // files to the bundle root, which is also where `Bundle.module.url(forResource:)` looks first.
        .target(name: "SheetNumbers", dependencies: ["SheetCore"], resources: [.process("Resources")]),
        .target(name: "SwiftSheets", dependencies: ["SheetCore", "SheetXLSX", "SheetCSV", "SheetODS", "SheetNumbers"]),
        // The direction matters: these depend on the umbrella (their conveniences extend its facade), and nothing
        // in the umbrella or the codecs depends on them — the moment it did, every product would carry the cipher.
        .target(name: "SheetDecrypt", dependencies: ["SwiftSheets"]),
        .target(name: "SheetEncrypt", dependencies: ["SheetDecrypt"]),
        .testTarget(
            name: "SwiftSheetsTests",
            dependencies: ["SwiftSheets"],
            resources: [.copy("Fixtures")]
        ),
        // Kept apart from SwiftSheetsTests so that the suite of the plain products never links a cipher.
        .testTarget(name: "SheetDecryptTests", dependencies: ["SheetDecrypt"]),
        .testTarget(name: "SheetEncryptTests", dependencies: ["SheetEncrypt"])
    ]
)
