# SwiftSheets — the plan

## Next steps (as of 2026-09-05)

- [x] An app that links only the products it needs still has every entrance — open, inspect, read and write row by row, convert — through the codec set `CodecSet` (0.18.0, Appendix B.44)
- [x] Encryption moved to separate products — the core carries no cipher; only an app that links `SheetDecrypt` (decrypting) or `SheetEncrypt` (encrypting) has one (0.17.0, Appendix B.39.9, Rev 4.29)
- [x] Pictures written to ODS — the one drawing the format used to drop (0.16.0, Appendix B.43)
- [x] Why the streaming read's peak grew with the file — two causes (an inflater piece too large for freed memory to leave the resident set; a file opened from a URL was mapped). Ten million cells streamed: XLSX 62 → 19 MB, ODS 709 → 14 MB, Numbers 329 → 61 MB. What XLSX and Numbers still add is the strings the reader must hold (0.17.2, Appendix B.39.8, Rev 4.31)
- [x] Why the ODS streaming read grew with the column count — the first cause above (the body inflated sixtyfold, one piece of 15 MB). A million cells: 228 → 15 MB (0.17.2, Appendix B.39.8, Rev 4.31)
- [ ] Add a real-world workbook, heavy with formatting and drawings, to the bench's material
- [x] Row-by-row writing in every format — the Excel-only streaming writer extended to ODS and Numbers
- [x] Release 0.14.0
- [x] Read several sheets side by side so a multi-sheet workbook is faster — the concurrency cap is the rein
- [x] Release 0.13.0
- [x] ODS, Numbers and CSV read row by row too — one call whatever the format
- [x] Measure speed and memory on a million-cell Numbers document and make the read twice as fast
- [x] Carry ODS workbook-structure protection and Excel's iterative-calculation settings
- [x] Release 0.11.2 — Linux support and the fixes for not crashing on damaged files, delivered first
- [x] Rebuild the ZIP reader and writer — files past 4 GB, and defences against decompression bombs
- [x] Ask a file for its sheets and cell counts before reading it, and let the reader set the limits
- [x] Detect a file's format without reading the whole file
- [x] Own XML tokenizer for faster reads
- [x] Read and write a large sheet piece by piece to bound memory
- [x] Read and write password-protected Excel and ODS files
- [x] Read only the sheets you want; read and write CSV row by row
- [x] Publish the measuring bench, so the numbers are measured rather than remembered
- [x] Release 0.12.0

## How this file is written

The section above is the whole plan. `- [ ]` is still to do, `- [x]` is done. Top to bottom, the first open item
is the next step. One line per item, in the user's words, under about 80 characters. The reasons and the history
are in the commit bodies and in Appendix B of the implementation spec.
