import Foundation

/// The cells a whole-workbook read may still hold (spec Appendix B.90): `ReadOptions.cellLimit`, shared by every
/// sheet of one read, sheets parsed side by side included. A reader takes an allowance at a time — `chunk` cells,
/// 4,096 or a sixty-fourth of a smaller limit — so the lock is taken once per allowance rather than once per cell,
/// and gives back what it did not use when its sheet ends. With no limit set there is no budget and nothing is
/// counted. While sheets run side by side one may still hold an allowance another could have used, so a read holds
/// at most the limit, never more; one sheet at a time, exactly the limit.
package final class CellBudget: @unchecked Sendable {
    package let limit: Int
    package let chunk: Int
    private var remaining: Int
    private let lock = NSLock()

    /// Nil for `Int.max`, the default: no limit, no budget.
    package init?(limit: Int) {
        guard limit < Int.max else { return nil }
        self.limit = Swift.max(0, limit)
        remaining = self.limit
        chunk = Swift.min(4096, Swift.max(16, self.limit / 64))
    }

    /// Up to one `chunk` of cells from what is left; 0 once the budget is spent.
    package func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let granted = Swift.min(chunk, remaining)
        remaining -= granted
        return granted
    }

    /// Returns cells taken and not used.
    package func giveBack(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); remaining += count; lock.unlock()
    }
}
