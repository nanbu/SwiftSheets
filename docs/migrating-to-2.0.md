# Migrating to 2.0

2.0 adds async versions of the calls that open, inspect, save and convert a workbook, under the same names as the
synchronous ones, and gives the `format:` argument 1.2.0 added its default (spec Appendix B.108). Both were announced
in 1.2.0. Synchronous code compiles and behaves as it did in 1.x. What changes is async code: there, Swift picks the
async version, so the call needs `await`. That is a source break, which is why this is 2.0.0. The compiler points at
every line and offers to insert the `await`; Swift 6.2 is still the minimum.

## Async code adds `await`

```swift
// 1.x, inside an async function
let opened = try Workbook.read(contentsOf: input)
_ = try opened.workbook.write(to: output, as: .xlsx)

// 2.0
let opened = try await Workbook.read(contentsOf: input)
_ = try await opened.workbook.write(to: output, as: .xlsx)
```

The calls this applies to, on `Workbook` and on any `CodecSet`: `read`, `inspect`, `write(as:)`, `write(to:)` and
`convert`. With SheetDecrypt and SheetEncrypt, their password forms, `decrypt` and `encrypt` too. The initializers,
`Workbook(contentsOf:)` and `Workbook(data:)`, stay synchronous and need no `await`; in async code,
`try await Workbook.read(contentsOf:).workbook` opens a file without holding your actor. The row-by-row
`StreamingReader` and `StreamingWriter` are unchanged.

The async version runs the same synchronous engine on your task, away from your actor (it is `@concurrent`; no
detached task is made). It is not faster and does not use less memory. What it adds is cancellation.

## Cancelling an async call

When the task is cancelled, an async call stops with `CancellationError`: before it starts, between the parts of a
package, every 64 KiB of XML, after a read (a read the task no longer wants is not handed back), and immediately
before a file is replaced. A write cancelled before that point leaves whatever was at the destination untouched; a
write that got past it has saved, and reports so. A step with no check inside it — a password's key derivation, a
CSV parse — runs to its end first, so cancellation is not a deadline.

Synchronous calls never stop for cancellation, even on a cancelled task. A save made while a task winds down, such
as a `defer` in a SwiftUI `.task`, still saves. To stop early, call the async version.

## `format:` has a default

`Workbook.read(contentsOf:)`, `Workbook.inspect(contentsOf:)`, `Workbook(contentsOf:)`, the same `CodecSet`
methods and their password forms are one function each since 2.0, taking `format: SheetFormat? = nil` as the calls
over bytes always have. 1.2.0 added the argument beside the functions without it; 2.0 gives it its default and
removes those. nil detects the format from the content, as before; a format skips detection, for a file whose
content cannot say what it is:

```swift
let opened = try Workbook.read(contentsOf: URL(filePath: "export.txt"), format: .csv)
```

A compound file (a protected package, a legacy `.xls`) is still refused by name, and a folder is only ever a Numbers
document; any other format given for a folder is `unrecognizedFormat`.

Every existing call compiles unchanged. One thing does not: naming one of these functions as a value by its old full
name, such as `let open = Workbook.read(contentsOf:options:)`. Write a closure instead,
`{ try Workbook.read(contentsOf: $0, options: $1) }`, or use the new name `Workbook.read(contentsOf:format:options:)`.

## Unchanged

Format detection, the way `write(to:)` picks an output format from the extension, every warning and error, the cell
values and the files written all stay as they were in 1.x. `write(to:)` still saves before it returns; to look at the
warnings before saving, call `write(as:)` and save its `data` yourself.
