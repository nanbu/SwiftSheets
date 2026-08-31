#!/usr/bin/env python3
"""The chart-sheet fixture — built by Microsoft Excel itself (spec Appendix B.35).

    python3 Tests/FixtureGenerator/make_chartsheet_fixture.py

A **chart sheet** is a chart that owns a whole tab: the workbook lists it beside the worksheets, but its part is
`<chartsheet>`, not `<worksheet>`. openpyxl can make one, but Excel's own is the specimen worth testing against —
and the question this fixture answers ("what does a chart sheet as Excel writes one do to our reader?") deserves
Excel's answer, not an imitation of it.

Needs Microsoft Excel, an unlocked screen, and this terminal allowed to control Excel in
System Settings ▸ Privacy & Security ▸ Automation. Any of them missing exits 2 ("cannot build"), never 1 —
the fixture is committed, so a machine that cannot drive Excel simply keeps the one in the repository.

Three things this script encodes so the next run does not rediscover them:

  * `make new chart sheet at end of <workbook>` is the whole trick — `count of sheets` then exceeds
    `count of worksheets`, which is how you check it worked.
  * The chart is empty until it is pointed at data, and the command is `set source data <chart> source <range>` —
    a *command with parameters*, not `set source data of <chart> to <range>`, which is a syntax error.
  * A `¬` continuation inside an `osascript -e` string is a parameter error (-50); keep each statement on one line.
  * Bind the worksheet as `worksheet 1 of wb`, never `active sheet of wb`. AppleScript keeps the *reference*, and
    adding the chart sheet makes that the active one — so a later `range "A1:B4" of ws` asks a chart for a range
    and fails with a parameter error (-50) that names nothing.
  * Never force-quit Excel: `quit saving no` is the only exit used here (a kill while it holds a modal raises the
    Microsoft error reporter, which is a second modal to clear).
"""
import pathlib
import subprocess
import sys

OUT = pathlib.Path(__file__).resolve().parents[1] / "SwiftSheetsTests" / "Fixtures" / "chartsheet.xlsx"


def cannot_build(why: str) -> None:
    print(f"cannot build: {why}\n(the committed fixture is unchanged)", file=sys.stderr)
    sys.exit(2)


def osa(script: str, timeout: int = 180) -> str:
    try:
        p = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        cannot_build("Excel stopped answering — a dialog is probably up on screen")
    if p.returncode != 0:
        message = (p.stderr or "").strip()
        if "-1743" in message or "not allowed" in message:
            cannot_build("this terminal is not allowed to control Excel "
                         "(System Settings ▸ Privacy & Security ▸ Automation)")
        if "-1728" in message:
            cannot_build(f"Excel could not find an object the script asked for: {message}")
        cannot_build(message or f"osascript exited {p.returncode}")
    return p.stdout.strip()


if not pathlib.Path("/Applications/Microsoft Excel.app").exists():
    cannot_build("Microsoft Excel is not installed")

# One worksheet of data, and a chart sheet drawn from it.
build = '''
with timeout of 170 seconds
tell application "Microsoft Excel"
  activate
  set wb to make new workbook
  set ws to worksheet 1 of wb
  set name of ws to "Data"
  set value of range "A1" of ws to "Item"
  set value of range "B1" of ws to "Qty"
  set value of range "A2" of ws to "apple"
  set value of range "B2" of ws to 3
  set value of range "A3" of ws to "pear"
  set value of range "B3" of ws to 5
  set value of range "A4" of ws to "plum"
  set value of range "B4" of ws to 2
  make new chart sheet at end of wb
  set cs to chart sheet 1 of wb
  set name of cs to "Quantities"
  set ch to chart of cs
  set source data ch source (range "A1:B4" of ws)
  set chart type of ch to column clustered
  return "sheets:" & (count of sheets of wb) & " worksheets:" & (count of worksheets of wb) & " chartsheets:" & (count of chart sheets of wb) & " series:" & (count of series of ch)
end tell
end timeout
'''
print(osa(build))

# Saved beside the fixture and moved into place only once Excel has produced a whole file, so a run that fails
# part-way leaves the committed fixture alone.
staging = OUT.with_suffix(".building.xlsx")
staging.unlink(missing_ok=True)
save = f'''
with timeout of 170 seconds
tell application "Microsoft Excel"
  save workbook as workbook 1 filename "{staging}"
  return full name of workbook 1
end tell
end timeout
'''
saved = osa(save)
osa('with timeout of 60 seconds\ntell application "Microsoft Excel" to quit saving no\nend timeout')

if not staging.exists():
    cannot_build(f"Excel reported saving to {saved} but the file is not there")

# What the tests rely on: the workbook lists two sheets and the second one's part is a <chartsheet>.
import zipfile
with zipfile.ZipFile(staging) as z:
    names = set(z.namelist())
    root = z.read("xl/chartsheets/sheet1.xml")[:400].decode("utf-8", "replace")
missing = {"xl/chartsheets/sheet1.xml", "xl/charts/chart1.xml", "xl/worksheets/sheet1.xml"} - names
if missing:
    cannot_build(f"the saved package is missing {sorted(missing)}")
if "<chartsheet" not in root:
    cannot_build("xl/chartsheets/sheet1.xml does not have a <chartsheet> root")
staging.replace(OUT)
print(f"✅ {OUT.relative_to(pathlib.Path(__file__).resolve().parents[2])} ({OUT.stat().st_size} B)")
