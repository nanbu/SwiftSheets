// swift-tools-version: 6.2
import PackageDescription

// Three executables, one per way of linking SwiftSheets, for scripts/check-no-crypto.sh (spec Appendix B.39.9,
// Rev 4.29): `plain` links the umbrella product only, `decrypt-only` adds SheetDecrypt, `full` adds SheetEncrypt.
// Each main uses the API it links, so that the linker pulls the library in — an executable that referenced nothing
// would prove nothing. The script reads their symbol tables.
let package = Package(
    name: "no-crypto",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "plain", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")]),
        .executableTarget(name: "decrypt-only", dependencies: [.product(name: "SheetDecrypt", package: "SwiftSheets")]),
        .executableTarget(name: "full", dependencies: [.product(name: "SheetEncrypt", package: "SwiftSheets")])
    ]
)
