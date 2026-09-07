/// How the sheet's content is represented, independently of whether its tab is visible (spec Appendix B.46).
public enum SheetContentState: Sendable, Hashable {
    /// A normal grid, including new and empty sheets. Reading losses are reported separately in readWarnings.
    case grid
    /// A worksheet left out by ReadOptions.sheets. XLSX can carry its original bytes; ODS and Numbers cannot.
    /// A sheet whose relationship already names another kind stays `.nonGrid` even when it is left out.
    /// Writing cells does not clear this state.
    case unread
    /// A sheet the model does not interpret as a grid, such as an XLSX chart sheet.
    case nonGrid
}
