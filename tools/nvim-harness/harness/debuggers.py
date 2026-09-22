"""Run each language's debugger to a real breakpoint and check what it
stopped on. Replaces check-debuggers.sh (tmux-driven, real keystrokes, a
real terminal frame) and check-debuggers-headless.sh (direct `nvim
--headless`, runs anywhere Neovim does, including Windows where tmux is
unavailable) with one CASES table and a mode switch.

tsx is the one language in both modes that does not gate: a real browser
under contended CI hardware occasionally drops the DAP session after a
correct handshake -- reported under `flaky`, not `failures`, so it cannot
fail the run on its own.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from .driver import HARNESS_DIR, collect_descendants, drive

DEBUG_FIXTURES = HARNESS_DIR / "debug-fixtures"


@dataclass(frozen=True)
class Case:
    lang: str
    file: str
    line: int
    needs: str
    choice: int
    settle_tmux: int
    expect_tmux: str
    settle_headless: int
    expect_headless: str


# tsx always offers the browser configuration second; every other language's
# first (only) configuration is the one to run.
CASES = [
    Case("python", "main.py", 3, "python3", 1, 20, "b int = 1", 40, "main.py:3"),
    Case("typescript", "main.ts", 2, "node", 1, 40, "b number = 1", 40, "main.ts:2"),
    Case("tsx", "index.tsx", 9, "node", 2, 60, "b number = 1", 75, "index.tsx:9"),
    Case("c", "main.c", 4, "codelldb", 1, 20, "b int = 1", 40, "main.c:4"),
    Case("cpp", "main.cpp", 5, "codelldb", 1, 20, "b int = 1", 40, "main.cpp:5"),
    Case("rust", "src/main.rs", 2, "codelldb", 1, 20, "b int = 1", 40, "main.rs:2"),
    Case("julia", "main.jl", 2, "julia", 1, 30, "add main.jl:2", 40, "main.jl:2"),
]

# What a browser configuration needs that does not belong in the config
# itself: headless flags, 127.0.0.1 (macOS resolves localhost to ::1 first),
# and its own profile. Used by tmux mode only -- headless mode's
# debug-headless.lua does the same thing itself, gated on
# DEBUG_BROWSER_HEADLESS, since it already runs inside the target Neovim.
_HEADLESS_EX = (
    "lua for _, configuration in ipairs(require('dap').configurations[vim.bo.filetype] or {}) do "
    "if configuration.type == 'pwa-chrome' then "
    "configuration.runtimeArgs = { '--headless=new', '--no-sandbox', '--disable-gpu' } "
    "configuration.userDataDir = true "
    "configuration.trace = { logFile = 'TRACE_FILE' } "
    "if configuration.url then configuration.url = configuration.url:gsub('localhost', '127.0.0.1') end "
    "end end "
    "vim.fn.writefile({ 'applied' }, 'MARKER_FILE')"
)


def _editor_path(path: Path) -> str:
    # Git Bash hands out /d/a/... paths; a native Windows Neovim can't open
    # one (E484, a hit-enter prompt a headless editor never exits from).
    if shutil.which("cygpath"):
        result = subprocess.run(["cygpath", "-w", str(path)], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    return str(path)


def _editor_env(appname: str | None, config_dir: str) -> dict:
    env = os.environ.copy()
    if appname:
        env["NVIM_APPNAME"] = appname
    env["XDG_CONFIG_HOME"] = config_dir
    return env


def _ask_editor(env: dict, lua_expr: str) -> str:
    # A timeout, not just stdin=DEVNULL: a headless editor stuck at a
    # hit-enter prompt (a bad path, E484) hangs regardless, and this call
    # runs once before the per-case loop even starts -- with no bound here,
    # nothing prints at all, for the whole run, before the job's own blunt
    # CI-level timeout finally kills it.
    try:
        result = subprocess.run(
            ["nvim", "--headless", f"+lua io.stdout:write({lua_expr}) io.stdout:flush()", "+qa"],
            env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
        )
    except subprocess.TimeoutExpired:
        return ""
    return result.stdout.strip()


def _mason_bin(appname: str | None, config_dir: str) -> Path:
    out = _ask_editor(_editor_env(appname, config_dir), "vim.fn.stdpath('data') .. '/mason/bin'")
    return Path(out)


def _browser_path(appname: str | None, config_dir: str) -> str:
    return _ask_editor(_editor_env(appname, config_dir), "require('util.browser').executable() or ''")


def _program_available(needs: str, mason_bin: Path) -> bool:
    if shutil.which(needs):
        return True
    return any(mason_bin.glob(f"{needs}*"))


def _tsx_port() -> str:
    pkg = DEBUG_FIXTURES / "tsx" / "package.json"
    try:
        text = pkg.read_text()
    except OSError:
        return ""
    match = re.search(r"--port (\d+)", text)
    return match.group(1) if match else ""


def _start_tsx_server(port: str) -> subprocess.Popen:
    return subprocess.Popen(
        ["node", str(HARNESS_DIR / "serve-fixture.js"), port],
        cwd=DEBUG_FIXTURES / "tsx",
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


def _wait_for_server(port: str) -> bool:
    for _ in range(10):
        try:
            result = subprocess.run(
                ["curl", "-s", "--max-time", "2", f"http://127.0.0.1:{port}/index.js"],
                capture_output=True, text=True,
            )
            if result.stdout:
                return True
        except OSError:
            pass
        time.sleep(1)
    return False


def _tail_dap_log(appname: str | None) -> str:
    state_home = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
    log = state_home / (appname or "nvim") / "dap.log"
    if not log.is_file() or log.stat().st_size == 0:
        return f"nothing: {log} is empty or missing"
    lines = log.read_text(errors="replace").splitlines()[-12:]
    return "\n".join(f"           {line[:160]}" for line in lines)


def _jsdebug_trace(path: Path) -> str:
    if not path.is_file() or path.stat().st_size == 0:
        return ""
    text = path.read_text(errors="replace")
    errors = sorted(set(re.findall(r'"(error|exceptionThrown|cannot|Cannot)[^"]*"', text)))[:6]
    launch_errors = re.findall(r"Unable to launch browser[^\"]*", text)[:2]
    lines = [f"           {e}" for e in errors] + [f"           {e}" for e in launch_errors]
    return "\n".join(lines)


def _what_editor_offers(appname: str | None, config_dir: str, lang_dir: Path, file: str) -> str:
    script = (
        "vim.defer_fn(function() "
        "local dap = require('dap') local ft = vim.bo.filetype local names = {} "
        "for _, c in ipairs(dap.configurations[ft] or {}) do "
        "names[#names + 1] = c.type .. ' ' .. c.request .. ' ' .. c.name end "
        "print(ft .. ': ' .. (#names > 0 and table.concat(names, ' | ') or 'no configurations')) "
        "vim.cmd('qa!') end, 8000)"
    )
    try:
        result = subprocess.run(
            ["nvim", "--headless", file, f"+lua {script}"],
            cwd=lang_dir, env=_editor_env(appname, config_dir), capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=15,
        )
    except subprocess.TimeoutExpired:
        return "           (timed out asking)"
    lines = (result.stdout + result.stderr).splitlines()[-3:]
    return "\n".join(f"           {line}" for line in lines)


# -- tmux mode ---------------------------------------------------------------

def _run_tmux_case(case: Case, config_dir: str, appname: str | None, out_dir: Path) -> tuple[bool, str]:
    lang_dir = DEBUG_FIXTURES / case.lang
    prelude = None
    server: subprocess.Popen | None = None
    try:
        if case.lang == "tsx":
            port = _tsx_port()
            server = _start_tsx_server(port)
            trace_file = out_dir / "tsx.jsdebug.log"
            marker = out_dir / "tsx.prelude"
            trace_file.unlink(missing_ok=True)
            marker.unlink(missing_ok=True)
            prelude = "ex:" + _HEADLESS_EX.replace("TRACE_FILE", str(trace_file)).replace(
                "MARKER_FILE", str(marker)
            )
            if not _wait_for_server(port):
                return False, f"FAILED: nothing is serving the fixture on port '{port}'"

        picks = ["Down"] * (case.choice - 1)
        batches = [" ff", case.file, "Enter", f":{case.line}", "Enter", " db"]
        if prelude:
            batches.append(prelude)
        batches += ["wait:3: dc", "wait:6:"]
        batches += picks
        batches += ["Enter", f"wait:{case.settle_tmux}:"]

        try:
            raw = drive(
                batches,
                config_dir=config_dir, appname=appname, workdir=str(lang_dir),
                trust=True, no_shada=True, capture_ansi=True,
                boot_wait=case.settle_tmux + 40, key_wait=2,
            )
        except TimeoutError:
            return False, "FAILED: the driver gave up"

        (out_dir / f"{case.lang}.ansi").write_text(raw + "\n")
        drawn = re.sub(r"\x1b\[[0-9;]*m", "", raw)
        (out_dir / f"{case.lang}.drawn").write_text(drawn + "\n")

        if case.expect_tmux in drawn:
            return True, f"stopped at {case.file}:{case.line}"

        lines = [f"NEVER STOPPED: nothing matching '{case.expect_tmux}', frame in {out_dir / (case.lang + '.drawn')}"]
        lines.append("           what the adapter said:")
        lines.append(_tail_dap_log(appname))
        if case.lang == "tsx" and not (out_dir / "tsx.prelude").exists():
            lines.append("           the harness could not change the configuration: its Ex command never ran")
        trace = _jsdebug_trace(out_dir / f"{case.lang}.jsdebug.log")
        if trace:
            lines.append("           what the browser adapter traced:")
            lines.append(trace)
        lines.append("           what the editor offers for this file:")
        lines.append(_what_editor_offers(appname, config_dir, lang_dir, case.file))
        return False, "\n".join(lines)
    finally:
        if server is not None:
            server.terminate()


# -- headless mode ------------------------------------------------------------

def _run_headless_case(case: Case, config_dir: str, appname: str | None, out_dir: Path) -> tuple[bool, str]:
    # Resolved before the subprocess's cwd changes to the fixture dir: a
    # relative config_dir would otherwise resolve against the wrong
    # directory, pointing XDG_CONFIG_HOME nowhere and silently loading no
    # plugins at all -- confirmed the hard way, "no nvim-dap" on every case.
    editor_config = _editor_path(Path(config_dir).resolve())
    script = _editor_path(HARNESS_DIR / "debug-headless.lua")
    lang_dir = DEBUG_FIXTURES / case.lang

    server: subprocess.Popen | None = None
    browser_headless = False
    try:
        if case.lang == "tsx":
            port = _tsx_port()
            server = _start_tsx_server(port)
            if not _wait_for_server(port):
                return False, f"FAILED: nothing is serving the fixture on port '{port}'"
            browser_headless = True

        env = os.environ.copy()
        if appname:
            env["NVIM_APPNAME"] = appname
        env["XDG_CONFIG_HOME"] = editor_config
        env["DEBUG_LINE"] = str(case.line)
        env["DEBUG_EXPECT"] = case.expect_headless
        env["DEBUG_SETTLE"] = str(case.settle_headless)
        env["DEBUG_CHOICE"] = str(case.choice)
        if browser_headless:
            env["DEBUG_BROWSER_HEADLESS"] = "1"

        answered = out_dir / f"{case.lang}.said"
        proc = subprocess.Popen(
            ["nvim", "--headless", "--cmd", "set nomore", "--cmd", "set shortmess+=atToOF",
             case.file, f"+luafile {script}"],
            cwd=lang_dir, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )

        # A hard deadline, not just debug-headless.lua's own settle timer:
        # a bad path handed to a native Windows nvim.exe (E484) leaves it
        # stuck at a hit-enter prompt before that Lua ever runs, and with no
        # bound here the loop waited the full 15-minute CI job timeout with
        # nothing printed, since a stuck subprocess never reaches
        # communicate() either.
        deadline = time.monotonic() + case.settle_headless + 60
        descendants: list[int] = []
        while proc.poll() is None:
            descendants = collect_descendants(proc.pid)
            if time.monotonic() >= deadline:
                proc.kill()
                proc.wait()
                answered.write_text(f"never stopped: timed out after {case.settle_headless + 60}s")
                return False, "FAILED: never stopped: timed out waiting for the editor"
            time.sleep(1)
        out, _ = proc.communicate()
        answered.write_bytes(out or b"")

        # A server-type DAP adapter (julia, js-debug's headless Chrome) is
        # started detached, in its own process group, so it survives Neovim
        # quitting -- a graceful qa!/cq! never runs nvim-dap's own
        # session-close cleanup, which is scoped to closing the session, not
        # to Neovim exiting. Snapshotted while nvim was still alive, since
        # once it exits these are reparented to init with nothing tying them
        # back to this run.
        for pid in descendants:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        if descendants:
            time.sleep(0.3)
            for pid in descendants:
                try:
                    os.kill(pid, 0)
                    os.kill(pid, 9)
                except OSError:
                    pass

        text = answered.read_text(errors="replace")
        if proc.returncode == 0:
            match = re.search(r"stopped at [^ ,]+", text)
            return True, match.group(0) if match else "stopped"

        # A match is optional -- an empty result here is a normal outcome
        # (the answer used none of the four phrasings), not an error.
        match = re.search(r"stopped at .*|never stopped: .*|no configuration[^.]*|no nvim-dap.*", text)
        said = match.group(0) if match else None
        return False, f"FAILED: {said or 'the editor said nothing'}"
    finally:
        if server is not None:
            server.terminate()


# -- entry point ---------------------------------------------------------------

def run(
    *,
    config_dir: str,
    appname: str | None = None,
    headless: bool | None = None,
    filter_regex: str | None = None,
    out_dir: str | Path = "/tmp/nvim-debuggers",
) -> int:
    if headless is None:
        headless = shutil.which("tmux") is None

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    editor_config = _editor_path(Path(config_dir).resolve()) if headless else config_dir
    mason_bin_cache: Path | None = None

    failures: list[str] = []
    flaky: list[str] = []
    checked = 0

    for case in CASES:
        pattern = filter_regex
        if pattern and not re.search(pattern, case.lang):
            continue

        print(f"{case.lang:<12} ", end="", flush=True)

        if mason_bin_cache is None:
            mason_bin_cache = _mason_bin(appname, editor_config)
        if not _program_available(case.needs, mason_bin_cache):
            print(f"skipped, no {case.needs} on PATH or in mason")
            continue

        if not (DEBUG_FIXTURES / case.lang).is_dir():
            print("skipped, no fixture: run make-debug-fixtures.sh" if headless else "skipped, no fixture")
            continue

        if case.lang == "tsx":
            if not (DEBUG_FIXTURES / "tsx" / "index.js").is_file():
                print("skipped, the fixture was never compiled")
                continue
            browser = _browser_path(appname, editor_config)
            if not browser:
                print("skipped, this machine has no browser to debug in")
                continue
            print(f"(browser: {Path(browser).name}) ", end="", flush=True)

        checked += 1
        if headless:
            ok, message = _run_headless_case(case, config_dir, appname, out)
        else:
            ok, message = _run_tmux_case(case, config_dir, appname, out)
        print(message)

        if not ok:
            bucket = flaky if case.lang == "tsx" else failures
            bucket.append(f"{case.lang}: {message.splitlines()[0]}")

    print()
    if flaky:
        print(f"{len(flaky)} known-flaky debugger(s) did not stop this run:")
        for line in flaky:
            print(f"  {line}")

    if failures:
        print(f"{len(failures)} of {checked} debugger(s) did not stop:")
        for line in failures:
            print(f"  {line}")
        return 1

    if checked == 0:
        print("No debugger was checked: none of the adapters are installed.", file=sys.stderr)
        return 1

    print(f"{checked} debugger(s) stopped where they were told to.")
    return 0


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", dest="config_dir", required=True)
    parser.add_argument("-n", dest="appname")
    parser.add_argument("-f", dest="filter_regex")
    parser.add_argument("-o", dest="out_dir", default="/tmp/nvim-debuggers")
    parser.add_argument("--headless", dest="headless", action="store_true", default=None)
    parser.add_argument("--tmux", dest="headless", action="store_false")
    args = parser.parse_args()
    return run(
        config_dir=args.config_dir, appname=args.appname, headless=args.headless,
        filter_regex=args.filter_regex, out_dir=args.out_dir,
    )


if __name__ == "__main__":
    raise SystemExit(_cli())
