// swift-tools-version: 6.2
import PackageDescription

// The measuring bench (spec Appendix B.39.11). A package of its own so that the library keeps no executable and
// no dependency for it; it depends on the library by path, so it always measures the checkout it sits in.
//
//   scripts/bench.sh            # builds it in release, runs every measurement in its own process, writes docs/performance.json
let package = Package(
    name: "swiftsheets-bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(name: "swiftsheets-bench", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")])
    ]
)
