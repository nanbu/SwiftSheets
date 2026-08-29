#!/usr/bin/env python3
"""The judge for sheet protection: Microsoft Excel itself is asked to unlock what SwiftSheets locked
(spec Appendix B.31). Everything else is a second opinion — our own `modernPasswordMatches`, an independent
Python-hashlib implementation of the same scheme. Only this one answers the question those cannot:

  does the hash we wrote let **Excel** in, and does a wrong password keep it out?

    python3 Tests/ExcelParity/verify_with_excel_app.py     # runs `swift test --filter ProtectionTests` first

Needs Microsoft Excel, an unlocked screen, and this terminal allowed to control Excel in
System Settings ▸ Privacy & Security ▸ Automation. Any of them missing is reported as "cannot judge" and
exits 2 — never as a failure of the files.

Four things this script learned the hard way and encodes so the next run does not rediscover them:

  * **Open through `open -a`, never AppleScript's `open POSIX file`.** Excel is sandboxed: told to open a path it
    has no grant for, it raises the macOS file-picker ("please select …") and answers no more Apple events.
    Going through LaunchServices hands Excel that one file and no dialog appears.
  * **Never force-quit Excel.** A kill while it holds a modal puts up the Microsoft error reporter, which is a
    second modal to clear. `quit saving no` is the only exit used here.
  * **Excel's start gallery blocks Apple events too.** With no document open, Excel shows the template chooser and
    stops answering; opening a document dismisses it. So a run that begins with a launch opens a file immediately.
  * **A wrong password raises nothing.** Excel returns from `unprotect` without error and simply leaves the sheet
    protected, so the verdict has to read the *state* (`protect contents`), never the absence of an error. That
    also fixes the order: the wrong password must be tried **first**, because `unprotect` on an already-unlocked
    sheet is a no-op that would pass for any password at all.
"""
import glob
import os
import pathlib
import subprocess
import sys

PKG = pathlib.Path(__file__).resolve().parents[2]
APP = "Microsoft Excel"
failures = []
notes = []

# (file, password, a password that is not it, what to read, what to unlock)
PROBES = [
    ("protect-ascii.xlsx", "secret", "wrongpass", "sheet", "an ASCII password on a sheet"),
    ("protect-japanese.xlsx", "秘密", "ちがう合言葉", "sheet", "a Japanese password (the UTF-16LE path)"),
    ("protect-workbook.xlsx", "book", "wrongbook", "workbook", "a password on the workbook's structure"),
]


def osa(script: str, timeout: int = 60) -> str:
    """Run AppleScript, mapping the two failures that mean 'cannot judge' rather than 'wrong'."""
    p = subprocess.run(["osascript", "-e", f"with timeout of {timeout - 10} seconds\n{script}\nend timeout"],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        message = (p.stderr or "").strip()
        if "-1743" in message or "not allowed" in message:
            cannot_judge("this terminal is not allowed to control Excel "
                         "(System Settings ▸ Privacy & Security ▸ Automation)")
        if "-1712" in message:
            raise TimeoutError("Excel stopped answering — a modal dialog is up (see the notes in this file)")
        raise RuntimeError(message or f"osascript exited {p.returncode}")
    return p.stdout.strip()


def cannot_judge(why: str) -> None:
    print(f"cannot judge: {why}")
    sys.exit(2)


def quit_excel() -> None:
    """The only way out. Never a kill — see the module docstring."""
    try:
        osa(f'tell application "{APP}"\n set display alerts to false\n'
            ' try\n close every workbook saving no\n end try\n'
            ' set display alerts to true\n quit saving no\nend tell', timeout=60)
    except Exception:
        pass


def probe(path: str, good: str, bad: str, kind: str) -> tuple[bool, bool, bool]:
    """Opens the file and returns (protected on open, still protected after the wrong password,
    still protected after the right one). The middle value is the control: without it, an Excel that
    ignored passwords entirely would pass."""
    subprocess.run(["open", "-a", APP, path], capture_output=True, timeout=120)
    target = "active sheet of active workbook" if kind == "sheet" else "active workbook"
    state = "protect contents of it" if kind == "sheet" else "protect structure of it"
    # Excel needs a moment to put the document up; the poll below is what waits, not a fixed sleep.
    opened = None
    for _ in range(20):
        try:
            answer = osa(f'tell application "{APP}"\n set display alerts to false\n'
                         f' set t to {target}\n if t is missing value then return "none"\n'
                         f' tell t to return ({state}) as string\nend tell', timeout=40)
        except TimeoutError:
            answer = "none"
        if answer in ("true", "false"):
            opened = answer == "true"
            break
        subprocess.run(["sleep", "1"], timeout=10)
    if opened is None:
        raise TimeoutError(f"Excel never showed {os.path.basename(path)}")

    def unlock(password: str) -> bool:
        return osa(f'tell application "{APP}"\n set t to {target}\n'
                   f' try\n unprotect t password "{password}"\n end try\n'
                   f' tell t to return ({state}) as string\nend tell', timeout=60) == "true"

    after_wrong = unlock(bad)
    after_good = unlock(good)
    osa(f'tell application "{APP}"\n set display alerts to false\n'
        ' try\n close every workbook saving no\n end try\nend tell', timeout=60)
    return opened, after_wrong, after_good


def main() -> int:
    if not pathlib.Path(f"/Applications/{APP}.app").exists():
        cannot_judge(f"{APP} is not installed")

    print("swift test --filter ProtectionTests …")
    r = subprocess.run(["swift", "test", "--filter", "ProtectionTests"], cwd=PKG,
                       capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        print("swift test ProtectionTests failed:\n" + r.stdout[-2000:])
        return 1
    dirs = sorted(glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "swiftsheets-protection-*")),
                  key=os.path.getmtime)
    if not dirs:
        cannot_judge("the probe workbooks were not written")
    probes = pathlib.Path(dirs[-1])

    version = osa(f'tell application "{APP}" to return version', timeout=60)
    print(f"{APP} {version}")
    try:
        for name, good, bad, kind, what in PROBES:
            path = probes / name
            if not path.exists():
                failures.append(f"{name} was not written")
                continue
            opened, after_wrong, after_good = probe(str(path), good, bad, kind)
            if not opened:
                failures.append(f"{what}: Excel did not see the file as protected at all")
            if not after_wrong:
                failures.append(f"{what}: Excel accepted the WRONG password — the hash is not being checked")
            if after_good:
                failures.append(f"{what}: Excel refused the correct password — the hash does not match Excel's")
            verdict = "ok" if (opened and after_wrong and not after_good) else "FAILED"
            print(f"  {name}: protected={opened} wrong-refused={after_wrong} "
                  f"right-accepted={not after_good} → {verdict}   ({what})")
    finally:
        quit_excel()

    for n in notes:
        print("note:", n)
    if failures:
        print("\n".join("FAIL: " + f for f in failures))
        return 1
    print(f"all {len(PROBES)} probes unlocked in {APP} {version}, and each refused a wrong password")
    return 0


if __name__ == "__main__":
    sys.exit(main())
