/// Cancellation for the async entry points (spec Appendix B.108). An async read, inspection, write or conversion
/// runs the synchronous engine inside `observing`, and the checks the engine makes — between the parts of a
/// package, every 64 KiB of markup, before a file is replaced — then stop it with `CancellationError` once its task
/// is cancelled. Called synchronously, the same engine runs to completion as it did in 1.x, even on a cancelled
/// task: a save made synchronously while a task winds down still saves.
package enum OperationCancellation {
    @TaskLocal private static var isObserved = false

    /// Runs `operation` so that the checks inside it answer to the current task's cancellation.
    package static func observing<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try $isObserved.withValue(true, operation: operation)
    }

    /// Throws `CancellationError` when an async entry point's task has been cancelled; does nothing otherwise.
    /// The task-local is read only once the task is cancelled, so the check costs one flag on the usual path.
    package static func check() throws {
        if Task.isCancelled, isObserved { throw CancellationError() }
    }
}
