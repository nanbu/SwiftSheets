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

- Refusing to read encrypted or password-protected files. This is intentional: they throw `unsupportedFeature`.
- Exceeding a documented limit (cell budget, formula nesting depth, ZIP64) and reporting it. See
  [Limits](README.md#limits).
- Formula evaluation. The library parses formulas; it does not execute them.
