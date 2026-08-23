import Foundation

/// What a range of cells accepts, and what the spreadsheet does about a value that does not fit
/// (`<dataValidation>`; spec appendix B.13).
///
/// **Write side only.** A validation read from a file is not turned into one of these: it stays in the sheet's
/// preserved XML and is written back byte for byte (`Sheet.hasUnmodelledValidations` says when a sheet has one).
/// Setting `Sheet.dataValidations` on a workbook built in memory is the supported use.
public struct DataValidation: Hashable, Sendable {
    /// What the cell must hold. `.none` is a rule that checks nothing (it can still carry an input message).
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case none, whole, decimal, list, date, time, textLength, custom
    }

    /// How the spreadsheet reacts to a value the rule rejects — only when `showErrorMessage` is on.
    public enum ErrorStyle: String, Hashable, Sendable, CaseIterable {
        /// Refuses the entry.
        case stop
        /// Asks, and takes the value if the person insists.
        case warning
        /// Tells, and takes the value.
        case information
    }

    /// How `formula1` (and `formula2`, for the two-sided ones) bounds the value.
    public enum Operator: String, Hashable, Sendable, CaseIterable {
        case between, notBetween, equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
    }

    public var kind: Kind
    /// The cells the rule covers (`sqref`).
    public var ranges: MultiCellRange
    /// The first operand, as formula text without the leading `=`: the source of a `.list`
    /// (`"'Choices'!$A$2:$A$4"`, or an inline `"\"a,b,c\""`), a bound, or the expression of a `.custom` rule.
    public var formula1: String?
    /// The second operand, for `.between` / `.notBetween`.
    public var formula2: String?
    public var `operator`: Operator?
    public var errorStyle: ErrorStyle?
    /// An empty cell passes.
    public var allowBlank: Bool
    /// **Inverted on purpose**: true HIDES the in-cell dropdown arrow of a `.list` rule. The file's attribute is
    /// spelled `showDropDown` but means exactly this (openpyxl calls it `hide_drop_down` for the same reason).
    public var hideDropDown: Bool
    /// Show `promptTitle` / `prompt` when the cell is selected.
    public var showInputMessage: Bool
    /// Show `errorTitle` / `error` — and act on `errorStyle` — when the value does not fit. **Off means the rule
    /// only suggests**: the dropdown is there and anything else typed in is still accepted.
    public var showErrorMessage: Bool
    public var errorTitle: String?
    public var error: String?
    public var promptTitle: String?
    public var prompt: String?
    /// Input-method mode for East Asian entry (`hiragana`, `halfAlpha`, …), verbatim.
    public var imeMode: String?

    /// Defaults are the file format's own (every flag off), not any application's dialog defaults.
    public init(kind: Kind, ranges: MultiCellRange, formula1: String? = nil, formula2: String? = nil,
                operator: Operator? = nil, errorStyle: ErrorStyle? = nil, allowBlank: Bool = false,
                hideDropDown: Bool = false, showInputMessage: Bool = false, showErrorMessage: Bool = false,
                errorTitle: String? = nil, error: String? = nil, promptTitle: String? = nil, prompt: String? = nil,
                imeMode: String? = nil) {
        self.kind = kind; self.ranges = ranges; self.formula1 = formula1; self.formula2 = formula2
        self.operator = `operator`; self.errorStyle = errorStyle; self.allowBlank = allowBlank
        self.hideDropDown = hideDropDown; self.showInputMessage = showInputMessage
        self.showErrorMessage = showErrorMessage; self.errorTitle = errorTitle; self.error = error
        self.promptTitle = promptTitle; self.prompt = prompt; self.imeMode = imeMode
    }

    /// A dropdown over `source` — a range reference such as `"'Choices'!$A$2:$A$4"`, or an inline list written
    /// `"\"a,b,c\""`.
    ///
    /// By default it **suggests**: the arrow is there, and a value that is not in the list is still accepted.
    /// Pass `rejects: true` for the strict form, which refuses anything else.
    public static func list(_ source: String, over ranges: MultiCellRange,
                            allowBlank: Bool = true, rejects: Bool = false) -> DataValidation {
        DataValidation(kind: .list, ranges: ranges, formula1: source, errorStyle: rejects ? .stop : nil,
                       allowBlank: allowBlank, showErrorMessage: rejects)
    }
}
