import Foundation

/// Where the schema, the registry and the empty template live. SwiftPM's bundle everywhere it has one; on
/// WebAssembly — which has no bundle and no host path worth baking in — a fixed directory the runtime is asked to
/// mount (`/SwiftSheets_SheetNumbers.resources`, the bundle's own name, so the same files serve both).
enum NumbersResources {
#if os(WASI)
    static let root = "/SwiftSheets_SheetNumbers.resources"
    static func url(_ name: String, _ ext: String) -> URL? { URL(fileURLWithPath: "\(root)/\(name).\(ext)") }
#else
    static func url(_ name: String, _ ext: String) -> URL? { Bundle.module.url(forResource: name, withExtension: ext) }
#endif
}
