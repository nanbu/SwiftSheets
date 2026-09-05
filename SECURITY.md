# Security Policy

## Supported versions

The latest 0.x release. There is no long-term support branch before 1.0.

## Reporting a vulnerability

Please **do not open a public issue.** Use GitHub's private reporting on this repository:
*Security* → *Report a vulnerability*. If that is unavailable to you, open an issue that says only that you have a
security report and asks for a contact — no details.

Expect a first response within a week. This is a single-maintainer project, so please allow reasonable time before
public disclosure.

## What is in scope

The library is expected to read hostile input safely. In scope:

- A crafted file that causes a crash, an abort, or unbounded memory or CPU use instead of a thrown error.
- A package whose entries escape the extraction target (path traversal), or whose declared sizes do not match what is
  extracted.
- A decompression ratio that defeats the built-in expansion cap.
- Anything that causes data from one workbook to leak into another.

## What is not in scope

- Refusing to read a protected file without its password, or the older encryption forms named in the README's
  Limits table. The plain products contain no cipher and refuse a protected file by name; opening one is the
  `SheetDecrypt` product's and protecting one `SheetEncrypt`'s. A defect in that arithmetic — a file that opens with
  the wrong password, or a written file that does not protect what it claims to — **is** in scope, and so is a
  crafted protected file that crashes the decrypting reader, and so would be any cipher symbol turning up in the
  plain products (`scripts/check-no-crypto.sh` runs in CI to keep that from happening in silence).
- Exceeding a documented limit (formula nesting depth, the package limits in `ReadOptions.limits`) and reporting it.
  See [Limits](README.md#limits).
- Memory used by a file that stays within those limits. There is no cell ceiling by default; a reader of untrusted
  files sets `ReadOptions.cellLimit` (and can ask `Workbook.inspect` how many cells a file declares before reading it).
- Formula evaluation. The library parses formulas; it does not execute them.
