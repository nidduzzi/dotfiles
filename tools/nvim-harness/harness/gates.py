"""Gate checks: assert something about the config, exit non-zero on failure.

Replaces check-syntax.sh, check-startup-plugins.sh, check-capability-keys.sh,
check-picker-keys.sh, check-startup-paths.sh, check-dismiss.sh and
check-key-names.sh. check-capability-keys/dismiss/startup-plugins shared an
identical control skeleton in bash (ensure the fixture exists, drive a `.lua`
probe with a report-file env var, assert the report is non-empty, parse it);
that skeleton is `run_lua_probe` below.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from .driver import HARNESS_DIR, drive, is_key_name
from .fixtures import build_fixture

CONFIG_ROOT_DEFAULT = os.environ.get(
    "NVIM_TOUR_CONFIG", str((HARNESS_DIR / ".." / ".." / ".worktrees" / "cfg").resolve())
)
APPNAME_DEFAULT = os.environ.get("NVIM_TOUR_APPNAME", "nvim-lazyvim")


def _config_dir(config_dir: str | None, appname: str | None) -> Path:
    return Path(config_dir or CONFIG_ROOT_DEFAULT) / (appname or APPNAME_DEFAULT)


def _ensure_fixture() -> Path:
    fixture = HARNESS_DIR / "fixture"
    if not fixture.exists():
        build_fixture(fixture)
    return fixture


def run_lua_probe(
    *,
    config_dir: str | None,
    appname: str | None,
    probe: str,
    out_env: str,
    wait_secs: int,
    extra_env: dict[str, str] | None = None,
    boot_wait: float = 60,
    key_wait: float = 3,
) -> str:
    """Drive the fixture, luafile a probe, return its report's content.

    The report path is exposed to the probe (and to Neovim generally) via
    `out_env` in the process environment -- subprocess.run's default
    behaviour inherits the calling environment, so setting it here reaches
    the launched Neovim the same way a bash `FOO=bar cmd` prefix did.
    """
    fixture = _ensure_fixture()

    fd, report_name = tempfile.mkstemp()
    os.close(fd)
    report_path = Path(report_name)

    env = {out_env: str(report_path), **(extra_env or {})}
    backup = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        drive(
            [f"wait:{wait_secs}:ex:luafile {HARNESS_DIR / probe}"],
            config_dir=config_dir, appname=appname, workdir=str(fixture),
            trust=True, no_shada=True, boot_wait=boot_wait, key_wait=key_wait,
        )
    finally:
        for k, v in backup.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    try:
        if report_path.stat().st_size == 0:
            return ""
        return report_path.read_text()
    finally:
        report_path.unlink(missing_ok=True)


# -- check-syntax --------------------------------------------------------

def check_syntax(config_dir: str | None = None) -> int:
    root = Path(config_dir) if config_dir else _config_dir(None, None)
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        return 2

    root = root.resolve()
    print(f"Checking {root}")

    if shutil.which("nvim") is None:
        print("nvim is required", file=sys.stderr)
        return 1

    files = sorted(
        p for p in root.rglob("*.lua")
        if ".git" not in p.parts and ".tests" not in p.parts
    )

    checked = 0
    failed = 0
    for f in files:
        checked += 1
        # loadfile compiles without executing, so a file with side effects is safe.
        lua = f"lua local f, err = loadfile('{f}') io.write(f and 'ok' or ('FAIL: ' .. tostring(err)))"
        result = subprocess.run(
            ["nvim", "--headless", "--clean", "-c", lua, "-c", "qa"],
            capture_output=True, text=True,
        ).stdout
        if result != "ok":
            failed += 1
            print(f"{f.relative_to(root)}\n  {result}")

    print()
    if checked == 0:
        print(f"No Lua files under {root}.")
        print("That is a wrong path, not a clean tree. Nothing was checked.")
        return 1

    if failed == 0:
        print(f"All {checked} Lua file(s) compile.")
        return 0
    print(f"{failed} of {checked} Lua file(s) failed to compile.")
    return 1


# -- check-startup-plugins ------------------------------------------------

def check_startup_plugins(config_dir: str | None = None, appname: str | None = None, update: bool = False) -> int:
    expected_path = HARNESS_DIR / "expected-startup-plugins.txt"
    report = run_lua_probe(
        config_dir=config_dir, appname=appname,
        probe="startup-plugins.lua", out_env="PROBE_OUT", wait_secs=5,
    )
    if not report:
        print("the editor reported no plugins at all", file=sys.stderr)
        return 1

    lines = report.splitlines()
    # LC_ALL=C: sort's order depends on locale, and a CI runner's C locale
    # sorts capitals first while this machine ignores case.
    found = sorted({ln[2:] if ln.startswith("  ") else ln for ln in lines[2:] if ln})

    if update:
        header = [ln for ln in expected_path.read_text().splitlines() if ln.startswith("#")]
        expected_path.write_text("\n".join(header + found) + "\n")
        print(f"baseline updated: {len(found)} plugins")
        return 0

    expected = sorted({
        ln for ln in expected_path.read_text().splitlines()
        if ln.strip() and not ln.startswith("#")
    })
    if found != expected:
        print("What loads at startup has changed:")
        added = sorted(set(found) - set(expected))
        removed = sorted(set(expected) - set(found))
        for ln in removed:
            print(f"  -{ln}")
        for ln in added:
            print(f"  +{ln}")
        print()
        print("A + is a plugin that now loads before you ask for it.")
        print("check-startup-plugins.sh -u accepts it, once it is deliberate.")
        return 1

    print(f"{lines[0]}, all expected.")
    return 0


# -- check-capability-keys -------------------------------------------------

def check_capability_keys(config_dir: str | None = None, appname: str | None = None) -> int:
    fixture = _ensure_fixture()
    report = run_lua_probe(
        config_dir=config_dir, appname=appname,
        probe="capability-keys.lua", out_env="CAPABILITY_KEYS_OUT", wait_secs=12,
        extra_env={"CAPABILITY_KEYS_FILE": str(fixture / "lib.lua")},
    )
    if not report:
        print("the capability list reported nothing at all", file=sys.stderr)
        return 1

    lines = report.splitlines()
    unbound = [ln[len("UNBOUND "):] for ln in lines if ln.startswith("UNBOUND ")]
    if unbound:
        print("The capability list offers keys nothing is bound to:")
        for ln in unbound:
            print(f"  {ln}")
        return 1

    print(f"{len(lines)} capability keys, all bound.")
    return 0


# -- check-picker-keys -------------------------------------------------

_SCENARIO_RE = re.compile(r'"[a-z-]+\|[^|]*\|[0-9]+\|[^"]*"')
_MODIFIER_KEY_RE = re.compile(r"^[MC]-.$")


def _driven_picker_keys() -> list[str]:
    # Static read of feature-tour.sh's own scenario strings -- switch to
    # importing tour.py's SCENARIOS once that phase of the port lands.
    text = (HARNESS_DIR / "feature-tour.sh").read_text()
    tokens: set[str] = set()
    for m in _SCENARIO_RE.finditer(text):
        for part in m.group(0).strip('"').split("|"):
            part = re.sub(r"^wait:[0-9]*:", "", part)
            if _MODIFIER_KEY_RE.match(part):
                tokens.add(part)
    return sorted(tokens)


def check_picker_keys(config_dir: str | None = None, appname: str | None = None) -> int:
    config_dir_p = _config_dir(config_dir, appname)
    fd, keys_name = tempfile.mkstemp()
    os.close(fd)
    keys_path = Path(keys_name)

    env = os.environ.copy()
    env["PICKER_KEYS_OUT"] = str(keys_path)
    env["XDG_CONFIG_HOME"] = str(config_dir_p.parent)
    env["NVIM_APPNAME"] = appname or APPNAME_DEFAULT
    try:
        subprocess.run(
            ["nvim", "--headless",
             "-c", 'lua require("lazy").load({ plugins = { "snacks.nvim" } })',
             "-c", f"luafile {HARNESS_DIR / 'picker-keys.lua'}",
             "-c", "qa"],
            env=env, capture_output=True, text=True,
        )
        if keys_path.stat().st_size == 0:
            print("the picker reported no keys at all", file=sys.stderr)
            return 1
        report = keys_path.read_text()
    finally:
        keys_path.unlink(missing_ok=True)

    status = 0
    driven = _driven_picker_keys()
    unbound = []
    for key in driven:
        bracketed = f"<{key}>"
        if (f"bound input {bracketed}".lower() not in report.lower()
                and f"bound list {bracketed}".lower() not in report.lower()):
            unbound.append(key)

    if unbound:
        print("The tour presses these inside a picker, and nothing is bound to them:")
        for key in unbound:
            print(f"  {key}")
        status = 1

    allowed_path = HARNESS_DIR / "expected-picker-overrides.txt"
    allowed = {
        ln for ln in allowed_path.read_text().splitlines()
        if ln.strip() and not ln.startswith("#")
    }
    overrides = {ln for ln in report.splitlines() if ln.startswith("override ")}
    undeclared = sorted(overrides - allowed)
    if undeclared:
        print("These picker keys already meant something to snacks:")
        for ln in undeclared:
            print(f"  {ln}")
        print()
        print(f"Add a line to {allowed_path.name} if that is deliberate.")
        status = 1

    if status == 0:
        bound = sum(1 for ln in report.splitlines() if ln.startswith("bound "))
        print(f"{bound} picker keys, {len(overrides)} of them taken from snacks, all declared.")
        print(f"{len(driven)} key(s) the tour presses inside a picker are bound.")
    return status


# -- check-startup-paths -------------------------------------------------

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def check_startup_paths(config_dir: str | None = None, appname: str | None = None) -> int:
    project = Path(tempfile.mkdtemp())
    try:
        (project / "src").mkdir()
        (project / "src" / "lib.lua").write_text("local M = {}\nreturn M\n")
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=project, check=True)
        subprocess.run(["git", "add", "-A"], cwd=project, check=True)
        subprocess.run(
            ["git", "-c", "user.email=t@e.invalid", "-c", "user.name=t", "commit", "-qm", "init"],
            cwd=project, check=True,
        )

        def asks(*batches: str, open_file: str | None = None) -> int:
            try:
                out = drive(
                    list(batches), config_dir=config_dir, appname=appname,
                    workdir=str(project), open_file=open_file,
                    no_shada=True, boot_wait=60, key_wait=3,
                )
            except TimeoutError:
                out = ""
            plain = _ANSI_RE.sub("", out)
            return plain.count("Trust this project")

        status = 0
        if asks("wait:5:ex:echo ''", open_file="src/lib.lua") == 0:
            print("  a file named on the command line was not asked about")
            status = 1

        if asks(" ff", "lib.lua", "wait:5:Enter") == 0:
            print("  a file opened from the picker was not asked about")
            status = 1

        # NVIM_APPNAME/XDG_CONFIG_HOME matter: the trust store lives under
        # stdpath("state"), which is per app name.
        config_dir_p = _config_dir(config_dir, appname)
        env = os.environ.copy()
        env["NVIM_APPNAME"] = appname or APPNAME_DEFAULT
        env["XDG_CONFIG_HOME"] = str(config_dir_p.parent)
        subprocess.run(
            ["nvim", "--headless", "-u", "NONE",
             "--cmd", f"set runtimepath+={config_dir_p}",
             f"+lua require('util.trust').allow('{project}')", "+qa"],
            env=env, capture_output=True, text=True,
        )

        if asks("wait:5:ex:echo ''", open_file="src/lib.lua") != 0:
            print("  a trusted project was asked about anyway")
            status = 1

        if status == 0:
            print("Asked on both ways in, and silent once trusted.")
        return status
    finally:
        shutil.rmtree(project, ignore_errors=True)


# -- check-dismiss -------------------------------------------------

def check_dismiss(config_dir: str | None = None, appname: str | None = None) -> int:
    fixture = _ensure_fixture()
    report = run_lua_probe(
        config_dir=config_dir, appname=appname,
        probe="dismiss-combinations.lua", out_env="DISMISS_OUT", wait_secs=90,
        extra_env={"DISMISS_FILE": str(fixture / "broken.py")},
        boot_wait=90,
    )
    if not report:
        print("the editor reported nothing at all", file=sys.stderr)
        return 1

    lines = report.splitlines()
    status = 0
    for line in lines:
        if line.startswith("start") or line.startswith("end"):
            if "python" not in line:
                print(f"the file went missing: {line}")
                status = 1
            continue
        name = line.split(" ", 1)[0]
        after = line.rsplit("after=", 1)[-1]
        opened = line.split(" opened=", 1)[-1].split(" after=", 1)[0]
        if after != "python":
            print(f"  {name} left something behind: {after}")
            status = 1
        elif opened == "python":
            print(f"  {name} never opened anything, so the press proved nothing")
            status = 1

    if status == 0:
        print(f"{len(lines) - 2} things open, each closed by one press, file untouched.")
    return status


# -- check-key-names -------------------------------------------------

def _emits_escape(socket: str, token: str) -> bool:
    subprocess.run(["tmux", "-L", socket, "send-keys", "--", token], capture_output=True, text=True)
    time.sleep(0.25)
    seen = subprocess.run(
        ["tmux", "-L", socket, "capture-pane", "-p"], capture_output=True, text=True
    ).stdout.replace("\n", "")
    subprocess.run(["tmux", "-L", socket, "send-keys", "C-u"], capture_output=True, text=True)
    time.sleep(0.1)
    # cat -v renders an incoming ESC byte as the literal two printable
    # characters "^[", not a raw escape byte -- that is what is being
    # searched for here, not "\x1b[".
    return "^[" in seen


_TOKEN_RE = re.compile(r"'(keys:)?[A-Za-z][A-Za-z0-9?$-]{0,12}'")


def check_key_names(dirs: list[str] | None = None) -> int:
    if shutil.which("tmux") is None:
        print("tmux is required", file=sys.stderr)
        return 1

    socket = f"key-name-check-{os.getpid()}"
    try:
        tokens: set[str] = set()
        for sh in sorted(HARNESS_DIR.glob("*.sh")):
            for m in _TOKEN_RE.finditer(sh.read_text()):
                tok = m.group(0).strip("'")
                if tok.startswith("keys:"):
                    tok = tok[len("keys:"):]
                tokens.update(tok.split())

        screens_dir = _config_dir(None, None) / "tests" / "screen"
        if screens_dir.is_dir():
            for kf in screens_dir.glob("*.keys"):
                for line in kf.read_text().splitlines():
                    if not line.strip() or line.startswith("#"):
                        continue
                    if line.startswith("keys:"):
                        line = line[len("keys:"):]
                    tokens.update(line.split())

        tokens = sorted(t for t in tokens if t)

        subprocess.run(
            ["tmux", "-L", socket, "-f", "/dev/null", "new-session", "-d",
             "-x", "60", "-y", "6", "cat -v"],
            capture_output=True, text=True,
        )
        time.sleep(0.5)

        bad = []
        for token in tokens:
            if is_key_name(token):
                continue
            if _emits_escape(socket, token):
                bad.append(token)

        print(f"checked {len(tokens)} batch spellings")
        if bad:
            for token in bad:
                print(f"  {token} is sent as a key by tmux, not as the characters")
            print()
            print(f"{len(bad)} batch(es) would be sent as a key rather than as text.")
            print("The drivers send text with -l, so this is about how a batch reads:")
            print("name the key deliberately, or keep it as text.")
            return 1

        print("No batch collides with a tmux key name.")
        return 0
    finally:
        subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True, text=True)
        tmux_tmpdir = os.environ.get("TMUX_TMPDIR", "/tmp")
        (Path(tmux_tmpdir) / f"tmux-{os.getuid()}" / socket).unlink(missing_ok=True)


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="gate", required=True)

    p = sub.add_parser("syntax")
    p.add_argument("config_dir", nargs="?")

    p = sub.add_parser("startup-plugins")
    p.add_argument("-c", dest="config_dir")
    p.add_argument("-n", dest="appname")
    p.add_argument("-u", dest="update", action="store_true")

    p = sub.add_parser("capability-keys")
    p.add_argument("-c", dest="config_dir")
    p.add_argument("-n", dest="appname")

    p = sub.add_parser("picker-keys")
    p.add_argument("-c", dest="config_dir")
    p.add_argument("-n", dest="appname")

    p = sub.add_parser("startup-paths")
    p.add_argument("-c", dest="config_dir")
    p.add_argument("-n", dest="appname")

    p = sub.add_parser("dismiss")
    p.add_argument("-c", dest="config_dir")
    p.add_argument("-n", dest="appname")

    p = sub.add_parser("key-names")
    p.add_argument("dirs", nargs="*")

    args = parser.parse_args()

    if args.gate == "syntax":
        return check_syntax(args.config_dir)
    if args.gate == "startup-plugins":
        return check_startup_plugins(args.config_dir, args.appname, args.update)
    if args.gate == "capability-keys":
        return check_capability_keys(args.config_dir, args.appname)
    if args.gate == "picker-keys":
        return check_picker_keys(args.config_dir, args.appname)
    if args.gate == "startup-paths":
        return check_startup_paths(args.config_dir, args.appname)
    if args.gate == "dismiss":
        return check_dismiss(args.config_dir, args.appname)
    if args.gate == "key-names":
        return check_key_names(args.dirs)
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
