"""Drive a key sequence and compare the resulting screen against a
committed one. Replaces screen-test.sh.

Per-test directives are `# name: value` lines at the top of a `.keys`
file: dir, size, needs, attempts, pause.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from .driver import HARNESS_DIR
from .normalise import normalise

CONFIG_ROOT_DEFAULT = os.environ.get(
    "NVIM_TOUR_CONFIG", str((HARNESS_DIR / ".." / ".." / ".worktrees" / "cfg").resolve())
)
APPNAME_DEFAULT = os.environ.get("NVIM_TOUR_APPNAME", "nvim-lazyvim")


def _read_directive(path: Path, name: str, fallback: str) -> str:
    pattern = re.compile(rf"^# *{re.escape(name)}: *(.*)$")
    for line in path.read_text().splitlines():
        m = pattern.match(line)
        if m:
            return m.group(1)
    return fallback


def _read_batches(path: Path) -> list[str]:
    return [
        line for line in path.read_text().splitlines()
        if line and not line.startswith("#") and line.strip()
    ]


def _capture(keys_file: Path, config_root: Path, appname: str) -> str:
    from .driver import drive

    workdir = Path(_read_directive(keys_file, "dir", str(HARNESS_DIR / "fixture")))
    size = _read_directive(keys_file, "size", "100x24")
    cols_str, _, rows_str = size.partition("x")
    cols, rows = int(cols_str), int(rows_str)

    if not workdir.is_dir():
        raise FileNotFoundError(f"No such directory: {workdir}")

    branch = subprocess.run(
        ["git", "-C", str(workdir), "branch", "--show-current"],
        capture_output=True, text=True,
    ).stdout.strip() or "NO_BRANCH"

    workdir_real = str(workdir.resolve())
    config_real = str(config_root.resolve())
    config_given = str(config_root)
    home = str(Path.home())
    workdir_tilde = workdir_real.replace(home, "~", 1) if workdir_real.startswith(home) else workdir_real
    config_tilde = config_given.replace(home, "~", 1) if config_given.startswith(home) else config_given

    pause = float(_read_directive(keys_file, "pause", "2"))
    batches = _read_batches(keys_file)

    captured = drive(
        batches,
        config_dir=str(config_root), appname=appname, workdir=str(workdir),
        trust=True, no_shada=True, capture_ansi=False,
        boot_wait=90, key_wait=pause, cols=cols, rows=rows,
    )
    # bash's pipeline (printf '%s\n' "$capture" | screen-normalise.py, whose
    # own CLI print()s each line) always leaves exactly one trailing newline
    # in the committed .expected files -- match that here rather than at
    # every call site.
    return normalise(
        captured,
        projects=[workdir_real, workdir_tilde],
        configs=[config_real, config_given, config_tilde],
        branch=branch,
    ) + "\n"


def _selected(tests_dir: Path, names: list[str]) -> list[Path]:
    if names:
        return [tests_dir / f"{name}.keys" for name in names]
    return sorted(tests_dir.glob("*.keys"))


def run(
    *,
    tests_dir: str | None = None,
    config_root: str | None = None,
    appname: str = APPNAME_DEFAULT,
    update: bool = False,
    with_lsp: bool = False,
    attempts: int = 3,
    names: list[str] | None = None,
) -> int:
    config_root_p = Path(config_root or CONFIG_ROOT_DEFAULT).resolve()
    # A fixed-length symlink, so a path that wraps a printed line wraps the
    # same place on every machine regardless of how long the real path is.
    stable_config = Path("/tmp/nvim-screen-cfg")
    stable_config.unlink(missing_ok=True)
    stable_config.symlink_to(config_root_p)
    config_root_p = stable_config

    tests_dir_p = Path(tests_dir) if tests_dir else config_root_p / appname / "tests" / "screen"
    if not tests_dir_p.is_dir():
        raise SystemExit(f"Not a directory: {tests_dir_p}")

    failed = 0
    checked = 0

    for keys_file in _selected(tests_dir_p, names or []):
        if not keys_file.is_file():
            print(f"No such test: {keys_file}", flush=True)
            failed += 1
            continue

        name = keys_file.stem
        expected = tests_dir_p / f"{name}.expected"
        print(f"{name:<28} ", end="", flush=True)

        needs = _read_directive(keys_file, "needs", "")
        if needs == "lsp" and not with_lsp:
            print("skipped, needs a language server (-l to run)")
            continue

        checked += 1

        if update or not expected.is_file():
            actual = _capture(keys_file, config_root_p, appname)
            expected.write_text(actual)
            print("updated" if update else "created")
            continue

        test_attempts = int(_read_directive(keys_file, "attempts", str(attempts)))
        matched = False
        actual = ""
        for attempt in range(1, test_attempts + 1):
            actual = _capture(keys_file, config_root_p, appname)
            if actual == expected.read_text():
                matched = True
                print("ok" if attempt == 1 else f"ok, on attempt {attempt}")
                break

        if not matched:
            print(f"CHANGED, after {test_attempts} attempts")
            import difflib
            diff = difflib.unified_diff(
                expected.read_text().splitlines(keepends=True),
                actual.splitlines(keepends=True),
                fromfile=f"{name}.expected", tofile=f"{name}.drawn",
            )
            print("".join(diff), end="")
            (tests_dir_p / f"{name}.drawn").write_text(actual)
            failed += 1

    print()
    if checked == 0:
        print(f"No screen tests under {tests_dir_p}.")
        return 1

    if failed > 0:
        print(f"{failed} of {checked} screens differ. Re-run with -u to accept them.")
        return 1

    print(f"{checked} screen(s) match.")
    return 0


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-d", dest="tests_dir")
    parser.add_argument("-c", dest="config_root")
    parser.add_argument("-n", dest="appname", default=APPNAME_DEFAULT)
    parser.add_argument("-u", dest="update", action="store_true")
    parser.add_argument("-l", dest="with_lsp", action="store_true")
    parser.add_argument("-t", dest="attempts", type=int, default=3)
    parser.add_argument("names", nargs="*")
    args = parser.parse_args()

    return run(
        tests_dir=args.tests_dir, config_root=args.config_root, appname=args.appname,
        update=args.update, with_lsp=args.with_lsp, attempts=args.attempts, names=args.names,
    )


if __name__ == "__main__":
    raise SystemExit(_cli())
