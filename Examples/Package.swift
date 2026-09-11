// swift-tools-version: 6.2
import PackageDescription

// The cookbook's code, as a package of its own so that every recipe is compiled — and run, on macOS — by CI against
// the checkout it sits in. docs/cookbook.md is generated from the files under Sources/swiftsheets-examples/Recipes by
// scripts/build-cookbook.py, so the page and the code cannot drift apart.
//
//   swift run --package-path Examples swiftsheets-examples all <directory>    # run every recipe in <directory>
//   swift run --package-path Examples swiftsheets-examples open-edit-save /tmp/x
let package = Package(
    name: "swiftsheets-examples",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "swiftsheets-examples",
            dependencies: [
                .product(name: "SwiftSheets", package: "SwiftSheets"),
                .product(name: "SheetCore", package: "SwiftSheets"),
                .product(name: "SheetXLSX", package: "SwiftSheets"),
                .product(name: "SheetODS", package: "SwiftSheets"),
            ])
    ]
)
