# Excel as a judge

`verify_with_excel_app.py` asks Microsoft Excel itself the one question no library can answer for us:
**does the sheet-protection hash we write actually let Excel in — and keep a wrong password out?**

```bash
python3 Tests/ExcelParity/verify_with_excel_app.py
```

It runs `swift test --filter ProtectionTests` first (which writes the probe workbooks to a temporary
directory), then drives Excel over AppleScript and reads the *state* of each document. Exit 0 means every
probe unlocked with its own password and refused a wrong one; exit 2 means the judge could not run at all
(no Excel, or this terminal is not allowed to control it in System Settings ▸ Privacy & Security ▸ Automation)
— never confused with a failure of the files.

Three probes, each carrying the **modern (SHA-512) hash only** so that a pass cannot be credited to the legacy
sixteen-bit hash sitting beside it: an ASCII password, a Japanese one (the UTF-16LE path), and one on the
workbook's structure (different attributes, different writer path). `ProtectedRange` is out of scope — there is
no clean way to ask Excel to unlock one.

The script's own docstring carries the four working rules this judge had to learn: open through `open -a`,
never force-quit Excel, expect the start gallery to block Apple events, and read state rather than errors —
Excel refuses a wrong password silently, and `unprotect` is a no-op once a sheet is already open, which is why
the wrong password is always tried first.

The result is recorded in the implementation spec, Appendix B.31.
