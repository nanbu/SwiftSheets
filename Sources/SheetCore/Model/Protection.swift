import CryptoKit
import Foundation

/// What a protected sheet still lets people do (`<sheetProtection>`).
///
/// The file format spells these the other way round — its `formatCells="1"` means formatting is *not* allowed — so
/// the names here say what is permitted and the codec does the inverting. `enabled` is the switch: with it off,
/// none of the rest has any effect.
///
/// Protecting a sheet is not security. The password stops a person from changing cells by accident; it is a
/// sixteen-bit hash that anyone determined can undo, and the cells themselves are stored in plain sight. Use it to
/// prevent mistakes, never to keep a secret.
public struct SheetProtection: Hashable, Sendable {
    /// The sheet is protected at all.
    public var enabled: Bool

    /// The legacy hash of the password (`password`), as four hexadecimal digits. Set it through `setPassword(_:)`.
    public package(set) var passwordHash: String?
    /// The modern hash Excel 2010 and later write (`algorithmName` / `hashValue` / `saltValue` / `spinCount`).
    /// A file that has one keeps it verbatim; `setModernPassword(_:)` computes a fresh one (Appendix B.31).
    public var algorithmName: String?
    public var hashValue: String?
    public var saltValue: String?
    public var spinCount: Int?

    public var allowsSelectingLockedCells: Bool
    public var allowsSelectingUnlockedCells: Bool
    public var allowsFormattingCells: Bool
    public var allowsFormattingColumns: Bool
    public var allowsFormattingRows: Bool
    public var allowsInsertingColumns: Bool
    public var allowsInsertingRows: Bool
    public var allowsInsertingHyperlinks: Bool
    public var allowsDeletingColumns: Bool
    public var allowsDeletingRows: Bool
    public var allowsSorting: Bool
    public var allowsFiltering: Bool
    public var allowsPivotTables: Bool
    /// Drawings, charts and comments may be edited.
    public var allowsEditingObjects: Bool
    public var allowsEditingScenarios: Bool

    /// The file format's own defaults: selection allowed, everything else not — which is what Excel's
    /// "Protect Sheet" dialog offers when you open it.
    public init(enabled: Bool = false, allowsSelectingLockedCells: Bool = true, allowsSelectingUnlockedCells: Bool = true,
                allowsFormattingCells: Bool = false, allowsFormattingColumns: Bool = false, allowsFormattingRows: Bool = false,
                allowsInsertingColumns: Bool = false, allowsInsertingRows: Bool = false, allowsInsertingHyperlinks: Bool = false,
                allowsDeletingColumns: Bool = false, allowsDeletingRows: Bool = false, allowsSorting: Bool = false,
                allowsFiltering: Bool = false, allowsPivotTables: Bool = false, allowsEditingObjects: Bool = true,
                allowsEditingScenarios: Bool = true) {
        self.enabled = enabled
        self.allowsSelectingLockedCells = allowsSelectingLockedCells
        self.allowsSelectingUnlockedCells = allowsSelectingUnlockedCells
        self.allowsFormattingCells = allowsFormattingCells
        self.allowsFormattingColumns = allowsFormattingColumns
        self.allowsFormattingRows = allowsFormattingRows
        self.allowsInsertingColumns = allowsInsertingColumns
        self.allowsInsertingRows = allowsInsertingRows
        self.allowsInsertingHyperlinks = allowsInsertingHyperlinks
        self.allowsDeletingColumns = allowsDeletingColumns
        self.allowsDeletingRows = allowsDeletingRows
        self.allowsSorting = allowsSorting
        self.allowsFiltering = allowsFiltering
        self.allowsPivotTables = allowsPivotTables
        self.allowsEditingObjects = allowsEditingObjects
        self.allowsEditingScenarios = allowsEditingScenarios
    }

    /// Protection on, with the defaults — the cells whose `CellStyle.protection.locked` is true (every cell, unless
    /// you say otherwise) become read-only.
    public static var on: SheetProtection { SheetProtection(enabled: true) }

    /// Sets — or with nil clears — the password, storing its legacy hash. Turning protection on is separate:
    /// `enabled` is the switch, this is the key.
    public mutating func setPassword(_ password: String?) {
        passwordHash = password.map(LegacyPasswordHash.hash)
    }

    /// True when `password` matches the stored legacy hash. Nil hash means no password was set.
    public func passwordMatches(_ password: String) -> Bool {
        guard let passwordHash else { return false }
        return LegacyPasswordHash.hash(password) == passwordHash
    }

    /// Sets — or with nil clears — the modern (SHA-512) password, filling `algorithmName` / `hashValue` /
    /// `saltValue` / `spinCount`. The legacy hash is separate and unchanged. Omit `salt` for 16 random bytes.
    public mutating func setModernPassword(_ password: String?, spinCount: Int = ModernPasswordHash.defaultSpinCount,
                                           salt: Data? = nil) {
        (algorithmName, hashValue, saltValue, self.spinCount) = ModernPasswordHash.fields(password, spinCount: spinCount, salt: salt)
    }

    /// True when `password` matches the stored modern hash. False when no modern hash is stored.
    public func modernPasswordMatches(_ password: String) -> Bool {
        ModernPasswordHash.matches(password, algorithmName: algorithmName, hashValue: hashValue,
                                   saltValue: saltValue, spinCount: spinCount)
    }

    public var isDefault: Bool { self == SheetProtection() }
}

/// Whether the shape of the workbook can be changed (`<workbookProtection>`): sheets added, removed, renamed or
/// unhidden, and where its windows sit. The same warning applies as for `SheetProtection` — this prevents
/// accidents, not determined people.
public struct WorkbookProtection: Hashable, Sendable {
    /// Sheets cannot be added, deleted, renamed, hidden or reordered.
    public var lockStructure: Bool
    /// The window layout is fixed.
    public var lockWindows: Bool
    /// Change tracking cannot be switched off.
    public var lockRevision: Bool
    public package(set) var passwordHash: String?
    public package(set) var revisionsPasswordHash: String?
    /// The modern hashes, carried verbatim.
    public var algorithmName: String?
    public var hashValue: String?
    public var saltValue: String?
    public var spinCount: Int?

    public init(lockStructure: Bool = false, lockWindows: Bool = false, lockRevision: Bool = false) {
        self.lockStructure = lockStructure; self.lockWindows = lockWindows; self.lockRevision = lockRevision
    }

    public mutating func setPassword(_ password: String?) { passwordHash = password.map(LegacyPasswordHash.hash) }
    public mutating func setRevisionsPassword(_ password: String?) { revisionsPasswordHash = password.map(LegacyPasswordHash.hash) }
    /// Sets — or with nil clears — the modern (SHA-512) password (Appendix B.31).
    public mutating func setModernPassword(_ password: String?, spinCount: Int = ModernPasswordHash.defaultSpinCount,
                                           salt: Data? = nil) {
        (algorithmName, hashValue, saltValue, self.spinCount) = ModernPasswordHash.fields(password, spinCount: spinCount, salt: salt)
    }
    /// True when `password` matches the stored modern hash. False when no modern hash is stored.
    public func modernPasswordMatches(_ password: String) -> Bool {
        ModernPasswordHash.matches(password, algorithmName: algorithmName, hashValue: hashValue,
                                   saltValue: saltValue, spinCount: spinCount)
    }
    public func passwordMatches(_ password: String) -> Bool {
        guard let passwordHash else { return false }
        return LegacyPasswordHash.hash(password) == passwordHash
    }
    public var isDefault: Bool { self == WorkbookProtection() }
}

/// A window in a protected sheet: cells that stay editable, optionally behind a password of their own
/// (`<protectedRange>`).
public struct ProtectedRange: Hashable, Sendable {
    public var name: String
    public var ranges: MultiCellRange
    public package(set) var passwordHash: String?
    public var algorithmName: String?
    public var hashValue: String?
    public var saltValue: String?
    public var spinCount: Int?
    /// The Windows security descriptor naming who may edit, verbatim.
    public var securityDescriptor: String?

    public init(name: String, ranges: MultiCellRange, securityDescriptor: String? = nil) {
        self.name = name; self.ranges = ranges; self.securityDescriptor = securityDescriptor
    }
    public init?(name: String, _ sqref: String) {
        guard let r = MultiCellRange(sqref) else { return nil }
        self.init(name: name, ranges: r)
    }
    public mutating func setPassword(_ password: String?) { passwordHash = password.map(LegacyPasswordHash.hash) }
    /// Sets — or with nil clears — the modern (SHA-512) password (Appendix B.31).
    public mutating func setModernPassword(_ password: String?, spinCount: Int = ModernPasswordHash.defaultSpinCount,
                                           salt: Data? = nil) {
        (algorithmName, hashValue, saltValue, self.spinCount) = ModernPasswordHash.fields(password, spinCount: spinCount, salt: salt)
    }
    /// True when `password` matches the stored modern hash. False when no modern hash is stored.
    public func modernPasswordMatches(_ password: String) -> Bool {
        ModernPasswordHash.matches(password, algorithmName: algorithmName, hashValue: hashValue,
                                   saltValue: saltValue, spinCount: spinCount)
    }
}

/// A named set of "what if" cell values (`<scenario>`): Excel puts them into the sheet on demand and takes the old
/// ones back out. The values are the file's own text — the format stores them that way, unresolved.
public struct Scenario: Hashable, Sendable {
    /// One cell a scenario changes.
    public struct InputCell: Hashable, Sendable {
        public var ref: CellRef
        /// The value as text (`val`). Empty means the scenario blanks the cell.
        public var value: String
        /// The cell has since been deleted from the sheet.
        public var deleted: Bool
        /// The change has been undone.
        public var undone: Bool
        /// A number format the scenario applies with the value.
        public var numberFormatID: Int?

        public init(_ ref: CellRef, _ value: String, deleted: Bool = false, undone: Bool = false, numberFormatID: Int? = nil) {
            self.ref = ref; self.value = value; self.deleted = deleted; self.undone = undone; self.numberFormatID = numberFormatID
        }
        public init?(_ a1: String, _ value: String) {
            guard let r = CellRef(a1) else { return nil }
            self.init(r, value)
        }
    }

    public var name: String
    public var cells: [InputCell]
    /// The scenario cannot be changed while the sheet is protected.
    public var locked: Bool
    /// The scenario does not appear in Excel's list.
    public var hidden: Bool
    /// Who last changed it, and their note.
    public var user: String?
    public var comment: String?

    public init(name: String, cells: [InputCell], locked: Bool = false, hidden: Bool = false,
                user: String? = nil, comment: String? = nil) {
        self.name = name; self.cells = cells; self.locked = locked; self.hidden = hidden
        self.user = user; self.comment = comment
    }
}

/// A sheet's scenarios, plus which of them Excel has selected (`<scenarios>`).
public struct ScenarioList: Hashable, Sendable, RandomAccessCollection, ExpressibleByArrayLiteral {
    public var scenarios: [Scenario]
    /// The one selected in Excel's dialog, by index.
    public var current: Int?
    /// The one whose values are in the sheet right now, by index.
    public var shown: Int?
    /// The cells the scenarios between them change (`sqref`).
    public var ranges: MultiCellRange?

    public init(_ scenarios: [Scenario], current: Int? = nil, shown: Int? = nil, ranges: MultiCellRange? = nil) {
        self.scenarios = scenarios; self.current = current; self.shown = shown; self.ranges = ranges
    }
    public init() { self.init([]) }
    public init(arrayLiteral elements: Scenario...) { self.init(elements) }

    public var startIndex: Int { 0 }
    public var endIndex: Int { scenarios.count }
    public subscript(i: Int) -> Scenario { scenarios[i] }
    public subscript(name: String) -> Scenario? { scenarios.first { $0.name == name } }
    public mutating func append(_ scenario: Scenario) { scenarios.append(scenario) }

    /// The cells every scenario between them touches, whether or not the file said so.
    public var touchedCells: MultiCellRange {
        if let ranges { return ranges }
        var m = MultiCellRange()
        for s in scenarios { for c in s.cells { m.add(CellRange(c.ref)) } }
        return m
    }
}

/// The sixteen-bit hash spreadsheets have stored passwords with since the 1990s (openpyxl `hash_password`).
///
/// It is a checksum, not a cipher: it keeps a colleague from editing a locked sheet by mistake, and it keeps
/// nothing from anyone who means to get in. The plain text is never stored, so a password cannot be read back out
/// of a file — only tested against.
public enum LegacyPasswordHash {
    /// openpyxl's `hash_password`, character for character. Each character is shifted by its own position, the bits
    /// that fall off the top are folded back in, and the length and a constant finish it off.
    ///
    /// The arithmetic is done in 64 bits, which is exact for every password up to 58 characters — past that the
    /// reference implementation's own accumulator grows beyond the four hexadecimal digits the file format has room
    /// for, so there is nothing faithful left to match.
    public static func hash(_ plaintext: String) -> String {
        var password: UInt64 = 0
        for (i, scalar) in plaintext.unicodeScalars.enumerated() {
            let shift = UInt64(i + 1)
            let value = UInt64(scalar.value)
            let shifted = shift < 43 ? value << shift : (value &<< (shift % 64))
            password ^= (shifted & 0x7FFF) | (shifted >> 15)
        }
        password ^= UInt64(plaintext.unicodeScalars.count)
        password ^= 0xCE4B
        return String(password, radix: 16, uppercase: true)
    }
}

/// The iterated SHA-512 hash Excel 2010 and later protect sheets with (ECMA-376 §18.2.29; Appendix B.31).
///
/// H₀ = SHA-512(salt ‖ UTF-16LE(password)); Hₙ = SHA-512(Hₙ₋₁ ‖ LE32(n−1)), `spinCount` times — the iteration
/// counter starts at 0 and is appended little-endian. Same warning as the legacy hash: this prevents accidents,
/// not determined people — the cells are stored in plain sight either way.
///
/// Adapted from XLKit (MIT — see NOTICE), whose implementation this matches round for round.
public enum ModernPasswordHash {
    /// Excel's own iteration count.
    public static let defaultSpinCount = 100_000
    /// What Excel writes as `algorithmName` for this scheme.
    public static let algorithmName = "SHA-512"

    /// The raw 64-byte hash for `plaintext` under `salt` and `spinCount` iterations.
    public static func hash(_ plaintext: String, salt: Data, spinCount: Int = defaultSpinCount) -> Data {
        precondition(spinCount > 0, "spinCount must be positive")
        let password = Data(plaintext.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })   // UTF-16LE
        var key = Data(SHA512.hash(data: salt + password))
        for i in 0..<UInt32(spinCount) {
            key = Data(SHA512.hash(data: key + withUnsafeBytes(of: i.littleEndian) { Data($0) }))
        }
        return key
    }

    /// 16 random bytes, from the system's cryptographically secure generator.
    static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        var salt = Data(capacity: 16)
        for _ in 0..<2 { withUnsafeBytes(of: generator.next() as UInt64) { salt.append(contentsOf: $0) } }
        return salt
    }

    /// The four attribute values for a protection element — or four nils when `plaintext` is nil.
    static func fields(_ plaintext: String?, spinCount: Int, salt: Data?)
        -> (algorithmName: String?, hashValue: String?, saltValue: String?, spinCount: Int?) {
        guard let plaintext else { return (nil, nil, nil, nil) }
        let salt = salt ?? randomSalt()
        let key = hash(plaintext, salt: salt, spinCount: spinCount)
        return (algorithmName, key.base64EncodedString(), salt.base64EncodedString(), spinCount)
    }

    /// True when `plaintext` reproduces `hashValue` under the stored salt and count. Only the scheme this type
    /// writes (`SHA-512`) can be checked; any other `algorithmName` answers false.
    static func matches(_ plaintext: String, algorithmName: String?, hashValue: String?,
                        saltValue: String?, spinCount: Int?) -> Bool {
        guard algorithmName == Self.algorithmName, let hashValue, let saltValue, let spinCount, spinCount > 0,
              let salt = Data(base64Encoded: saltValue), let stored = Data(base64Encoded: hashValue) else { return false }
        return hash(plaintext, salt: salt, spinCount: spinCount) == stored
    }
}
