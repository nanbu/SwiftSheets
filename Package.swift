// swift-tools-version: 6.2
import PackageDescription

// SwiftSheets — a Swift-idiomatic take on openpyxl's core API for reading and writing .xlsx workbooks.
// Pure Swift, Foundation + Compression only, no external dependencies. Designed to live in its own repository.
let package = Package(
    name: "SwiftSheets",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SwiftSheets", targets: ["SwiftSheets"])
    ],
    targets: [
        .target(name: "SwiftSheets"),
        .testTarget(
            name: "SwiftSheetsTests",
            dependencies: ["SwiftSheets"],
            resources: [.copy("Fixtures")]
        )
    ]
)
