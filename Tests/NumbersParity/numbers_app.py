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

Three things on the machine, not in the file, stop this cold: macOS asks once, on screen, whether this terminal may
control Numbers; a **locked screen** leaves Numbers unable to open a document window — after which it answers no
property of that document at all; and the application the judge reaches may not be Apple's Numbers at all, because
a bundle identifier is a claim a bundle makes about itself and LaunchServices resolves claims. `available()` names
all three rather than letting a suite fail as if the files were bad.

    python3 Tests/NumbersParity/numbers_app.py which                          # what com.apple.Numbers resolves to
"""
# `str | None` in an annotation is evaluated at import time before Python 3.10, and this runs on the
# system Python 3.9. PEP 563 leaves every annotation unevaluated, which is what makes it safe here.
from __future__ import annotations

import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

BUNDLE = "com.apple.Numbers"
# The authorities only Apple signs under: the Mac App Store's re-signing of a purchased application, and the one
# an application shipped inside the system image carries. A leaf certificate is what proves the bundle is Apple's,
# because the identifier in an Info.plist proves nothing — see `apple_numbers`. Deliberately *not* checked: the
# team identifier (this Mac's genuine copy carries `JCRTNEU7GK` in its code directory and `5KR58Z2G5J` in its
# entitlement, so neither is a stable fact), and the requirement `anchor apple` (which a Mac App Store copy of
# Numbers does not satisfy — measured 2026-08-26 — because Apple re-signs it the way it re-signs everyone's).
_APPLE_AUTHORITIES = ("Apple Mac OS Application Signing", "Software Signing")
DEFAULT_TIMEOUT = 180
# Numbers is sandboxed. It cannot read another process's private temp directory — the `$TMPDIR/swiftsheets-numbers-*`
# the Swift tests write into — and says so with "the operation is not permitted" in a dialog nobody is there to click.
# Every document is copied into the package's own .build first, which it opens without complaint, and every file it
# writes is written there and moved afterwards.
STAGE = pathlib.Path(__file__).resolve().parents[2] / ".build" / "numbers-judge"


class NumbersUnavailable(RuntimeError):
    """Numbers.app is not installed, or this terminal has not been allowed to control it."""


class NumbersNotApple(RuntimeError):
    """`com.apple.Numbers` resolved to a bundle Apple did not sign. A verdict from it would be a verdict about
    another program, so there is no verdict — see `apple_numbers`."""


class NumbersTimeout(RuntimeError):
    """Numbers stopped answering — almost always a modal dialog (a repair prompt) nobody can click."""


class NumbersAnsweredAboutAnotherDocument(RuntimeError):
    """Numbers answered about a document other than the one it was asked about — a failed measurement, not a
    verdict on the file. See `_clean_slate` (spec Appendix B.19)."""


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


def _clean_slate(timeout: int = 120) -> None:
    """No document open, and none waiting to be restored.

    Every script here picks the document up through `front document`, so a window left over from an earlier call
    is a document a later call will answer about instead — and a Numbers killed with `killall -9` puts its whole
    last session **back** on the next launch. Measured on 2026-08-26: two documents that were byte-identical in
    their archives answered differently, and a run that asked Numbers to save one document saved another
    (spec Appendix B.19). Closing every document and quitting *gracefully* is what stops it; `_verify_answered`
    is the second half, catching the case where it happens anyway."""
    if subprocess.run(["pgrep", "-x", "Numbers"], capture_output=True).returncode != 0:
        return          # not running: nothing to clear, and speaking to it would only launch it
    subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE}" to close every document saving no'],
                   capture_output=True, timeout=timeout)


def _wait_until_gone(seconds: float = 20.0) -> None:
    """`killall -9` returns before the kernel has reaped the process, and LaunchServices answers -600 for a moment
    after that. `_clean_slate` waits for the graceful quit; the retry path did not wait for the forced one, which
    is why a second `open` could land in the same gap it was retrying because of."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if subprocess.run(["pgrep", "-x", "Numbers"], capture_output=True).returncode != 0:
            break
        time.sleep(0.5)
    time.sleep(2)          # LaunchServices settles a moment after the process is gone


def _verify_answered(staged: str, answered: str) -> None:
    """The document Numbers answered about has to be the one it was asked about. Numbers names a document by its
    file name, minus the extension for one it imported — so the stem is what matches. A mismatch is a failed
    measurement, never a fact about the file."""
    stem = os.path.splitext(os.path.basename(staged))[0]
    first = answered.split("|")[0].strip() if "|" in answered else answered.strip()
    if not first.startswith(stem):
        raise NumbersAnsweredAboutAnotherDocument(
            f"asked about {os.path.basename(staged)}, Numbers answered about {first[:60]!r}")


def _launch_open(path: str, timeout: int) -> None:
    """`open -a <the authenticated Numbers> <file>`, onto a clean slate. LaunchServices grants the sandboxed
    application access to what it is asked to open; AppleScript's own `open` does not, and a document outside the
    places Numbers may read anyway comes back as "the operation is not permitted" — in a dialog, with nobody there
    to click it. The application is named by path, not by the name "Numbers", so the bundle `apple_numbers` proved
    is the bundle that opens the document."""
    app = _app()          # authenticated first: `_clean_slate` speaks to whatever claims the bundle id
    _clean_slate(timeout)
    for attempt in range(3):
        p = subprocess.run(["open", "-a", app, path], capture_output=True, text=True, timeout=timeout)
        if p.returncode == 0:
            return
        # -600 is "no such process": LaunchServices caught the application mid-shutdown, which happens right after
        # a document it refused was cleared away. Give it a clean slate, wait for it, and ask again.
        if "-600" in p.stderr and attempt < 2:
            quit_app(force=True)
            _wait_until_gone()
            continue
        raise RuntimeError(p.stderr.strip() or f"open -a {app} exited {p.returncode}")


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


def resolved_app() -> str | None:
    """The path LaunchServices sends `com.apple.Numbers` to, or None. Asked before a word is said to the
    application, because this is the question `id of application id` cannot answer: it echoes the identifier back."""
    p = subprocess.run(["osascript", "-e", f'POSIX path of (path to application id "{BUNDLE}")'],
                       capture_output=True, text=True, timeout=60)
    return p.stdout.strip().rstrip("/") or None


def _signature(path: str) -> dict:
    """What the signature on the bundle says — the identifier Apple signed and the chain that signed it.
    `codesign -dv` prints to stderr, and checks the signature over the code directory, so the identifier it
    reports is the signed one rather than whatever the Info.plist on disk currently claims."""
    p = subprocess.run(["codesign", "-dv", "--verbose=4", path], capture_output=True, text=True, timeout=120)
    out: dict = {"authorities": []}
    for line in p.stderr.splitlines():
        key, _, value = line.partition("=")
        if key == "Authority":
            out["authorities"].append(value)
        elif key in ("Identifier", "TeamIdentifier"):
            out[key] = value
    return out


def apple_numbers() -> tuple[str | None, str]:
    """(path, what proved it) for Apple's own Numbers, or (None, why not) — the check that has to come first.

    A bundle identifier is a claim a bundle makes about itself, and LaunchServices resolves claims: any bundle
    whose Info.plist says `com.apple.Numbers` is what `id of application id "com.apple.Numbers"` answers about
    and what `tell application id` then drives. So the judge takes the resolved **path** and reads the signature
    on it; an authority only Apple can sign under is the proof.

    The path is not the proof, and a whitelist of paths would be wrong: on this Mac (measured 2026-08-26) Apple's
    own Numbers 15.3.1 sits at `/Applications/Numbers Creator Studio.app` — the bundle takes its name from the
    base `CFBundleDisplayName`, while every `.lproj` localises the name back to "Numbers"."""
    path = resolved_app()
    if not path:
        return None, "no application answers to com.apple.Numbers — Numbers.app is not installed"
    if not os.path.exists(path):
        return None, f"com.apple.Numbers resolves to {path}, and nothing is there"
    sig = _signature(path)
    identifier = sig.get("Identifier", "")
    leaf = (sig["authorities"] or ["(unsigned)"])[0]
    if identifier != BUNDLE or leaf not in _APPLE_AUTHORITIES:
        return None, (f"com.apple.Numbers resolves to {path}, which Apple did not sign — signed identifier "
                      f"{identifier or '(none)'}, authority {leaf}. Whatever that is, its answers would be about "
                      f"another program, so this judge stands down rather than report on it.")
    seal = subprocess.run(["codesign", "--verify", path], capture_output=True, text=True, timeout=600)
    if seal.returncode != 0:
        return None, (f"{path} is signed by Apple but the seal is broken, so what runs is not what was signed: "
                      f"{seal.stderr.strip() or 'codesign --verify failed'}")
    return path, f"{path} (signed {identifier}, {leaf})"


_APP: str | None = None


def _app() -> str:
    """The bundle every launch goes through, authenticated once per process, so the application that was checked
    is the application that gets driven — `open -a Numbers` would resolve the name all over again."""
    global _APP
    if _APP is None:
        path, why = apple_numbers()
        if not path:
            raise NumbersNotApple(why)
        _APP = path
    return _APP


def available() -> tuple[bool, str]:
    """(usable, why not). Answers without opening a document, so it is safe to call from a test setup."""
    app, why = apple_numbers()
    if not app:
        return False, why
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
    return True, f"{version} at {why}"


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
    answer = _run(script, [staged], timeout)
    _verify_answered(staged, answer.split("|", 1)[1] if answer.startswith("clean|") else answer)
    return answer


def dump(path: str, timeout: int = DEFAULT_TIMEOUT, max_rows: int = 200, max_cols: int = 40) -> dict:
    """What Numbers itself makes of the document: every sheet, table, and cell's value, formatted value and
    formula — the last one being the only way to ask whether a formula archive we generated really is a formula."""
    script = _PROLOGUE + '''
      with timeout of 600 seconds
        try
          set d to my waitForDocument()
          set out to "{\\"document\\":" & my q(name of d) & ",\\"sheets\\":["
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
    answer = json.loads(_run(script, [staged], timeout))
    _verify_answered(staged, answer.get("document", ""))
    return answer


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
          set n to name of d
          close d saving no
          return "exported|" & n
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
    _verify_answered(staged, result.split("|", 1)[-1])
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
          set n to name of d
          close d saving no
          return "saved|" & n
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
    _verify_answered(staged, result.split("|", 1)[-1])
    if staged_out.exists() and str(staged_out) != out_path:
        shutil.move(str(staged_out), out_path)
    return result


def main(argv: list[str]) -> int:
    if argv and argv[0] == "which":
        # Answerable without launching anything, which is the point: it is the one question worth asking when a
        # run reports something that cannot be true of the files.
        app, why = apple_numbers()
        print(why)
        return 0 if app else 2
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
    except (NumbersTimeout, NumbersUnavailable, NumbersNotApple, RuntimeError) as e:
        print(f"{type(e).__name__}: {e}", file=sys.stderr)
        return 1
    finally:
        quit_app()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, lambda *_: (quit_app(force=True), sys.exit(130)))
    sys.exit(main(sys.argv[1:]))
