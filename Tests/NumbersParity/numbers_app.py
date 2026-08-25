#!/usr/bin/env python3
"""Drives Numbers.app over AppleScript so the application itself can judge what SwiftSheets writes
(spec §11.3, Appendix B.18). Everything else in the Numbers suite is a second opinion — our own reader,
numbers-parser, LibreOffice's importer. This one is the first opinion: the program the files are for.

Used as a module by verify_with_numbers_app.py, and on its own:

    python3 Tests/NumbersParity/numbers_app.py open   <file.numbers>          # opened clean? (the repair check)
    python3 Tests/NumbersParity/numbers_app.py dump   <file.numbers>          # values / formatted values / formulas as JSON
    python3 Tests/NumbersParity/numbers_app.py export <in> <out.xlsx|.csv|.pdf|.numbers>
    python3 Tests/NumbersParity/numbers_app.py resave <in.xlsx|.ods|…> <out.numbers>   # let Numbers produce the document

Every call runs under two timeouts — AppleScript's own and a hard one here — because a modal Numbers puts up
(“this document needs to be repaired”, an unexpected alert) answers no events at all. On a hard timeout the
application is killed, so the next call starts from a clean slate instead of inheriting the stuck dialog.

Two things on the machine, not in the file, stop this cold: macOS asks once, on screen, whether this terminal may
control Numbers, and a **locked screen** leaves Numbers unable to open a document window — after which it answers
no property of that document at all. `available()` names both rather than letting a suite fail as if the files
were bad.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys

BUNDLE = "com.apple.Numbers"
DEFAULT_TIMEOUT = 180
# Numbers is sandboxed. It cannot read another process's private temp directory — the `$TMPDIR/swiftsheets-numbers-*`
# the Swift tests write into — and says so with "the operation is not permitted" in a dialog nobody is there to click.
# Every document is copied into the package's own .build first, which it opens without complaint, and every file it
# writes is written there and moved afterwards.
STAGE = pathlib.Path(__file__).resolve().parents[2] / ".build" / "numbers-judge"


class NumbersUnavailable(RuntimeError):
    """Numbers.app is not installed, or this terminal has not been allowed to control it."""


class NumbersTimeout(RuntimeError):
    """Numbers stopped answering — almost always a modal dialog (a repair prompt) nobody can click."""


# Numbers' `open` answers `missing value`, so every script picks the document up from the application afterwards —
# through `front document`, never through the `documents` element: on Numbers 15.3.1 counting or listing documents
# never answers at all, while `exists front document` answers at once.
_WAIT_FOR_DOCUMENT = """
on waitForDocument()
  tell application id "com.apple.Numbers"
    repeat 120 times
      if exists front document then return front document
      delay 0.25
    end repeat
    error "Numbers opened no document" number -43
  end tell
end waitForDocument
"""


def _run(script: str, args: list[str], timeout: int) -> str:
    argv = ["osascript", "-", *args]
    if "waitForDocument" in script:
        script += _WAIT_FOR_DOCUMENT
    try:
        p = subprocess.run(argv, input=script, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        quit_app(force=True)
        raise NumbersTimeout(f"Numbers did not answer within {timeout}s (a modal dialog?)")

    out, err = p.stdout.strip(), p.stderr.strip()
    if p.returncode != 0 or out.startswith("ERROR|"):
        message = out[6:] if out.startswith("ERROR|") else err
        if "-1712" in message or "timed out" in message or "タイムアウト" in message:
            quit_app(force=True)
            raise NumbersTimeout(message)
        if "-1743" in message or "not allowed" in message:
            raise NumbersUnavailable(message)
        # "the document is damaged", "the operation is not permitted" — Numbers says either in a modal sheet that
        # only a person can dismiss. Kill it, so the next call is not answering last call's dialog.
        quit_app(force=True)
        raise RuntimeError(message or f"osascript exited {p.returncode}")
    return out


def _launch_open(path: str, timeout: int) -> None:
    """`open -a Numbers <file>`. LaunchServices grants the sandboxed application access to what it is asked to
    open; AppleScript's own `open` does not, and a document outside the places Numbers may read anyway comes
    back as "the operation is not permitted" — in a dialog, with nobody there to click it."""
    for attempt in range(2):
        p = subprocess.run(["open", "-a", "Numbers", path], capture_output=True, text=True, timeout=timeout)
        if p.returncode == 0:
            return
        # -600 is "no such process": LaunchServices caught the application mid-shutdown, which happens right after
        # a document it refused was cleared away. Give it a clean slate and ask once more.
        if "-600" in p.stderr and attempt == 0:
            quit_app(force=True)
            continue
        raise RuntimeError(p.stderr.strip() or f"open -a Numbers exited {p.returncode}")


def _stage(path: str) -> str:
    """A copy of the document where Numbers is allowed to read it. A .numbers is a file here and a bundle
    elsewhere, so both are handled."""
    src = pathlib.Path(path).resolve()
    STAGE.mkdir(parents=True, exist_ok=True)
    dst = STAGE / src.name
    if dst == src:
        return str(dst)
    _clear(dst)
    (shutil.copytree if src.is_dir() else shutil.copy2)(src, dst)
    return str(dst)


def _clear(path: pathlib.Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def quit_app(force: bool = False) -> None:
    """Leave no window behind. `force` is for a Numbers that is already past talking to."""
    if force:
        subprocess.run(["killall", "-9", "Numbers"], capture_output=True)
        return
    subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE}" to quit saving no'],
                   capture_output=True, timeout=30)


def screen_is_locked() -> bool:
    """A locked Mac is the one failure that looks exactly like a broken document: Numbers takes the `open`, cannot
    put a window on a locked screen, and then answers no property of the document at all. Worth naming for what
    it is rather than reporting the file as bad."""
    p = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True, timeout=30)
    return "CGSSessionScreenIsLocked" in p.stdout


def installed() -> bool:
    p = subprocess.run(["osascript", "-e", f'id of application id "{BUNDLE}"'], capture_output=True, text=True, timeout=30)
    return p.returncode == 0


def available() -> tuple[bool, str]:
    """(usable, why not). Answers without opening a document, so it is safe to call from a test setup."""
    if not installed():
        return False, "Numbers.app is not installed"
    if screen_is_locked():
        return False, ("the screen is locked — Numbers cannot open a document window on a locked Mac and stops "
                       "answering AppleEvents; unlock it and run again")
    try:
        version = _run('tell application id "com.apple.Numbers" to return version as text', [], 60)
    except NumbersTimeout:
        return False, ("Numbers is not answering AppleEvents — allow this terminal to control Numbers in "
                       "System Settings ▸ Privacy & Security ▸ Automation, then run again")
    except NumbersUnavailable as e:
        return False, str(e)
    except Exception as e:  # noqa: BLE001 - any failure here means "cannot judge", never "the file is bad"
        return False, str(e)
    return True, version


_PROLOGUE = f'''
on run argv
  set thePath to item 1 of argv
  tell application id "{BUNDLE}"
'''


def opens_clean(path: str, timeout: int = DEFAULT_TIMEOUT) -> str:
    """"clean" when Numbers opened the document and answered afterwards. A file it wants to repair puts up a
    modal, which is what the timeout catches; anything else comes back as the error Numbers itself gave."""
    script = _PROLOGUE + '''
      with timeout of 120 seconds
        try
          set d to my waitForDocument()
          set n to name of d
          set c to count of sheets of d
          close d saving no
          return "clean|" & n & "|" & (c as text)
        on error errMsg number errNum
          try
            close every document saving no
          end try
          return "ERROR|" & errMsg & " (" & (errNum as text) & ")"
        end try
      end timeout
    end tell
end run

'''
    staged = _stage(path)
    _launch_open(staged, timeout)
    return _run(script, [staged], timeout)


def dump(path: str, timeout: int = DEFAULT_TIMEOUT, max_rows: int = 200, max_cols: int = 40) -> dict:
    """What Numbers itself makes of the document: every sheet, table, and cell's value, formatted value and
    formula — the last one being the only way to ask whether a formula archive we generated really is a formula."""
    script = _PROLOGUE + '''
      with timeout of 600 seconds
        try
          set d to my waitForDocument()
          set out to "{\\"sheets\\":["
          set sheetCount to count of sheets of d
          repeat with si from 1 to sheetCount
            set s to sheet si of d
            if si > 1 then set out to out & ","
            set out to out & "{\\"name\\":" & my q(name of s) & ",\\"tables\\":["
            set tableCount to count of tables of s
            repeat with ti from 1 to tableCount
              set t to table ti of s
              if ti > 1 then set out to out & ","
              set nr to count of rows of t
              set nc to count of columns of t
              if nr > ''' + str(max_rows) + ''' then set nr to ''' + str(max_rows) + '''
              if nc > ''' + str(max_cols) + ''' then set nc to ''' + str(max_cols) + '''
              set out to out & "{\\"name\\":" & my q(name of t) & ",\\"rows\\":" & (nr as text) & ",\\"columns\\":" & (nc as text) & ",\\"cells\\":["
              set firstCell to true
              repeat with ri from 1 to nr
                repeat with ci from 1 to nc
                  set c to cell ci of row ri of t
                  set v to value of c
                  if v is not missing value then
                    if not firstCell then set out to out & ","
                    set firstCell to false
                    set f to formula of c
                    set fv to formatted value of c
                    set out to out & "{\\"row\\":" & ((ri - 1) as text) & ",\\"column\\":" & ((ci - 1) as text)
                    set out to out & ",\\"value\\":" & my q(v as text) & ",\\"formatted\\":" & my q(fv as text)
                    if f is not missing value then set out to out & ",\\"formula\\":" & my q(f as text)
                    set out to out & "}"
                  end if
                end repeat
              end repeat
              set out to out & "]}"
            end repeat
            set out to out & "]}"
          end repeat
          set out to out & "]}"
                    close d saving no
          return out
        on error errMsg number errNum
          try
            close every document saving no
          end try
          return "ERROR|" & errMsg & " (" & (errNum as text) & ")"
        end try
      end timeout
    end tell
end run

on q(t)
  set s to t as text
  set out to "\\""
  repeat with ch in characters of s
    set c to ch as text
    if c is "\\"" then
      set out to out & "\\\\\\""
    else if c is "\\\\" then
      set out to out & "\\\\\\\\"
    else if (id of c) < 32 then
      set out to out & "\\\\u" & my hex4(id of c)
    else
      set out to out & c
    end if
  end repeat
  return out & "\\""
end q

on hex4(n)
  set digits to "0123456789abcdef"
  set out to ""
  repeat with shift in {4096, 256, 16, 1}
    set d to (n div shift) mod 16
    set out to out & (character (d + 1) of digits)
  end repeat
  return out
end hex4
'''
    staged = _stage(path)
    _launch_open(staged, timeout)
    return json.loads(_run(script, [staged], timeout))


_FORMATS = {".pdf": "PDF", ".xlsx": "Microsoft Excel", ".csv": "CSV", ".numbers": "Numbers 09"}


def export(path: str, out_path: str, timeout: int = DEFAULT_TIMEOUT) -> str:
    """Have Numbers write the document out in another format — the judge for "and the values survive"."""
    ext = os.path.splitext(out_path)[1].lower()
    if ext not in _FORMATS:
        raise ValueError(f"Numbers exports {', '.join(sorted(_FORMATS))}, not {ext}")
    out_path = os.path.abspath(out_path)
    _clear(pathlib.Path(out_path))
    STAGE.mkdir(parents=True, exist_ok=True)
    staged_out = STAGE / os.path.basename(out_path)
    _clear(staged_out)
    script = _PROLOGUE + f'''
      set outPath to item 2 of argv
      with timeout of 300 seconds
        try
          set d to my waitForDocument()
          export d to (POSIX file outPath) as {_FORMATS[ext]}
          close d saving no
          return "exported"
        on error errMsg number errNum
          try
            close every document saving no
          end try
          return "ERROR|" & errMsg & " (" & (errNum as text) & ")"
        end try
      end timeout
    end tell
end run
'''
    staged = _stage(path)
    _launch_open(staged, timeout)
    result = _run(script, [staged, str(staged_out)], timeout)
    # A CSV export of a multi-sheet document becomes a folder of files; Numbers decides, we only move what appeared.
    if staged_out.exists() and str(staged_out) != out_path:
        shutil.move(str(staged_out), out_path)
    return result


def resave(path: str, out_path: str, timeout: int = DEFAULT_TIMEOUT) -> str:
    """Open something Numbers can import (.xlsx, .csv, an older .numbers) and save it as a Numbers document.
    This is how a fixture with a feature we cannot yet write — a conditional format, a formula — is made:
    build it in a format we do write, and let Numbers produce the archives."""
    out_path = os.path.abspath(out_path)
    _clear(pathlib.Path(out_path))
    STAGE.mkdir(parents=True, exist_ok=True)
    staged_out = STAGE / os.path.basename(out_path)
    _clear(staged_out)
    script = _PROLOGUE + '''
      set outPath to item 2 of argv
      with timeout of 300 seconds
        try
          set d to my waitForDocument()
          save d in (POSIX file outPath)
          close d saving no
          return "saved"
        on error errMsg number errNum
          try
            close every document saving no
          end try
          return "ERROR|" & errMsg & " (" & (errNum as text) & ")"
        end try
      end timeout
    end tell
end run
'''
    staged = _stage(path)
    _launch_open(staged, timeout)
    result = _run(script, [staged, str(staged_out)], timeout)
    if staged_out.exists() and str(staged_out) != out_path:
        shutil.move(str(staged_out), out_path)
    return result


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    ok, why = available()
    if not ok:
        print(f"Numbers.app cannot be driven: {why}", file=sys.stderr)
        return 3
    command = argv[0]
    try:
        if command == "open":
            print(opens_clean(argv[1]))
        elif command == "dump":
            print(json.dumps(dump(argv[1]), ensure_ascii=False, indent=1))
        elif command == "export":
            print(export(argv[1], argv[2]))
        elif command == "resave":
            print(resave(argv[1], argv[2]))
        else:
            print(__doc__)
            return 2
    except (NumbersTimeout, NumbersUnavailable, RuntimeError) as e:
        print(f"{type(e).__name__}: {e}", file=sys.stderr)
        return 1
    finally:
        quit_app()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, lambda *_: (quit_app(force=True), sys.exit(130)))
    sys.exit(main(sys.argv[1:]))
