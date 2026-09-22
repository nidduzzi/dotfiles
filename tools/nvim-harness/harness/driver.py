"""Drive an isolated Neovim instance inside a dedicated tmux server and
capture what it renders. Replaces nvim-drive.sh; film.py extends this for
frame-by-frame recording.

RPC goes over a persistent pynvim connection rather than one `nvim --server
--remote-expr` subprocess per call -- no Vimscript-string quoting for `ex:`
batches, and no macOS RPC-flakiness fallback needed.
"""
from __future__ import annotations

import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Sequence

import pynvim

HARNESS_DIR = Path(__file__).resolve().parent.parent

KEY_NAMES = {
    "Space", "Enter", "Escape", "Tab", "BSpace", "BTab",
    "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
    "IC", "DC", "NPage", "PPage",
}
_FUNCTION_KEY = re.compile(r"^F([0-9]|1[0-2])$")

# ANTHROPIC_API_KEY is deliberately not forwarded: nothing here drives that
# API, and a key in the environment is one any program the editor starts
# can read.
ENV_FORWARD = (
    "CUSTOM_BASE_URL",
    "CUSTOM_API_KEY",
    "HERMES_ALLOW_PRIVATE_URLS",
    "HERMES_INFERENCE_PROVIDER",
    "HERMES_INFERENCE_MODEL",
)


def is_key_name(key: str) -> bool:
    """tmux resolves DC/IC/etc. as key names before treating them as text."""
    if key in KEY_NAMES:
        return True
    if key.startswith(("C-", "M-", "S-")):
        return True
    return bool(_FUNCTION_KEY.match(key))


def collect_descendants(root_pid: int) -> list[int]:
    """Every process under root_pid, root first. One `ps` call plus a walk
    in Python, not `ps --ppid`, which is GNU-only and doesn't run on macOS.
    """
    try:
        out = subprocess.run(
            ["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True
        ).stdout
    except OSError:
        return []
    children: dict[int, list[int]] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)

    found: list[int] = []

    def walk(pid: int) -> None:
        for child in children.get(pid, ()):
            found.append(child)
            walk(child)

    walk(root_pid)
    return found


def _lua_str(value: object) -> str:
    s = str(value).replace("\\", "\\\\").replace("'", "\\'")
    return f"'{s}'"


class NvimDriver:
    """One tmux server, one Neovim instance, one pynvim connection."""

    def __init__(
        self,
        *,
        config_dir: str | None = None,
        appname: str | None = None,
        workdir: str | None = None,
        socket: str | None = None,
        cols: int = 120,
        rows: int = 40,
        boot_wait: float = 3,
        key_wait: float = 1,
        capture_ansi: bool = False,
        keep: bool = False,
        open_file: str | None = None,
        trust: bool = False,
        force_trust: bool = False,
        no_shada: bool = False,
    ) -> None:
        self.config_dir = Path(config_dir).resolve() if config_dir else None
        self.appname = appname
        self.workdir = Path(workdir).resolve() if workdir else Path.cwd()
        self.socket = socket or f"nvim-harness-{os.getpid()}"
        self.cols = cols
        self.rows = rows
        self.boot_wait = boot_wait
        self.key_wait = key_wait
        self.capture_ansi = capture_ansi
        self.keep = keep
        self.open_file = open_file
        self.trust = trust
        self.force_trust = force_trust
        self.no_shada = no_shada

        self.rpc_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"nvim-drive-{os.getpid()}.sock"
        self._nvim: pynvim.Nvim | None = None
        self._started = False

    def _tmux(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["tmux", "-L", self.socket, *args], capture_output=True, text=True
        )

    # -- trust -----------------------------------------------------------

    def _trust_env(self) -> dict:
        env = os.environ.copy()
        if self.appname:
            env["NVIM_APPNAME"] = self.appname
        if self.config_dir:
            env["XDG_CONFIG_HOME"] = str(self.config_dir)
        return env

    def _within_harness(self) -> bool:
        return self.workdir == HARNESS_DIR or str(self.workdir).startswith(str(HARNESS_DIR) + os.sep)

    def _apply_trust(self) -> None:
        if not self.trust:
            return
        allowed = self._within_harness() or self.force_trust

        if allowed:
            config_root = self.config_dir or (Path.home() / ".config")
            rtp = f"{config_root}/{self.appname or 'nvim'}"
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE",
                 "--cmd", f"set runtimepath+={rtp}",
                 f"+lua require('util.trust').allow({_lua_str(self.workdir)})",
                 "+qa"],
                env=self._trust_env(), capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Could not trust {self.workdir}", file=sys.stderr)

        nvim_lua = self.workdir / ".nvim.lua"
        if nvim_lua.is_file():
            if allowed:
                result = subprocess.run(
                    ["nvim", "--headless", "-u", "NONE",
                     f"+lua vim.secure.trust({{ action = 'allow', path = {_lua_str(nvim_lua)} }})",
                     "+qa"],
                    env=self._trust_env(), capture_output=True, text=True,
                )
                if result.returncode != 0:
                    print(f"Could not pre-trust {nvim_lua}", file=sys.stderr)
            else:
                print(f"Refusing to trust {self.workdir}/.nvim.lua without -F.", file=sys.stderr)
                print("It is Lua from that project, and trusting it runs it.", file=sys.stderr)
                raise SystemExit(3)

    # -- startup -----------------------------------------------------------

    def _clear_swap(self) -> None:
        if not self.appname:
            return
        state_home = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
        swap_dir = state_home / self.appname / "swap"
        if swap_dir.is_dir():
            for f in swap_dir.iterdir():
                try:
                    f.unlink()
                except OSError:
                    pass

    def _launch_command(self) -> str:
        parts = ["env"]
        if self.appname:
            parts.append(f"NVIM_APPNAME={shlex.quote(self.appname)}")
        if self.config_dir:
            parts.append(f"XDG_CONFIG_HOME={shlex.quote(str(self.config_dir))}")
        for name in ENV_FORWARD:
            value = os.environ.get(name)
            if value:
                parts.append(f"{name}={shlex.quote(value)}")
        parts.append("nvim")
        parts.append(f"--listen {shlex.quote(str(self.rpc_path))}")
        if self.no_shada:
            parts.append("-i NONE")
        # argc affects when LazyVim wires its autocmds (eager vs lazy), so
        # opening a file on the command line is a different startup path
        # from opening it once running.
        if self.open_file:
            parts.append(shlex.quote(self.open_file))
        return " ".join(parts)

    def _wait_ready(self) -> None:
        deadline = time.monotonic() + self.boot_wait
        patient_until = time.monotonic() + self.boot_wait / 2
        while time.monotonic() < deadline:
            if self.rpc_path.exists():
                if self._nvim is None:
                    try:
                        self._nvim = pynvim.attach("socket", path=str(self.rpc_path))
                    except Exception:
                        self._nvim = None
                if self._nvim is not None:
                    try:
                        if bool(self._nvim.eval(
                            'v:vim_did_enter == 1 && get(g:, "dotfiles_ready", v:false) == v:true'
                        )):
                            return
                        # A stock LazyVim baseline never sets dotfiles_ready;
                        # accepted after half the timeout.
                        if time.monotonic() >= patient_until and bool(self._nvim.eval("v:vim_did_enter")):
                            return
                    except Exception:
                        self._nvim = None
            time.sleep(0.2)
        raise TimeoutError(f"Neovim did not become ready within {self.boot_wait}s")

    def _wait_lazy(self) -> None:
        # vim_did_enter fires before lazy.nvim finishes; give up quietly if
        # this configuration does not use lazy at all.
        deadline = time.monotonic() + self.boot_wait
        while time.monotonic() < deadline:
            try:
                ready = self._nvim.exec_lua(
                    'return package.loaded["lazy.core.loader"] ~= nil and vim.g.lazy_did_setup == true'
                )
            except Exception:
                ready = False
            if ready:
                return
            time.sleep(0.2)

    def start(self) -> None:
        self._tmux("kill-server")
        self._clear_swap()
        self._apply_trust()
        self.rpc_path.unlink(missing_ok=True)

        self._tmux(
            "-f", "/dev/null", "new-session", "-d",
            "-x", str(self.cols), "-y", str(self.rows),
            "-c", str(self.workdir), self._launch_command(),
        )
        self._wait_ready()
        self._wait_lazy()
        self._started = True

    # -- batches -----------------------------------------------------------

    def send_keys(self, tokens: Sequence[str]) -> None:
        for tok in tokens:
            if is_key_name(tok):
                self._tmux("send-keys", tok)
            else:
                self._tmux("send-keys", "-l", "--", tok)

    def run_ex(self, cmd: str) -> None:
        # <C-\><C-N> first: an Ex command executed while a buffer is in
        # insert mode would otherwise be typed into it instead of run.
        try:
            self._nvim.input("<C-\\><C-N>")
            self._nvim.command(cmd)
        except Exception:
            # RPC dropped -- fall back to typed keys.
            self._tmux("send-keys", "-l", f":{cmd}")
            self._tmux("send-keys", "Enter")

    def send_batch(self, batch: str) -> float:
        """Send one batch, return the seconds the caller should then wait."""
        wait_for = self.key_wait
        if batch.startswith("wait:"):
            rest = batch[len("wait:"):]
            wait_str, _, batch = rest.partition(":")
            wait_for = float(wait_str)

        if batch.startswith("ex:"):
            self.run_ex(batch[len("ex:"):])
        elif batch.startswith("keys:"):
            self.send_keys(batch[len("keys:"):].split())
        else:
            self.send_keys([batch])
        return wait_for

    # -- capture -----------------------------------------------------------

    def _grab(self) -> str:
        args = ["capture-pane", "-p"]
        if self.capture_ansi:
            args.append("-e")
        args += ["-N", "-S", "0", "-E", str(self.rows - 1)]
        # Matches bash's $(...) command substitution: trailing newlines
        # stripped, so a single print() adds exactly one back.
        return self._tmux(*args).stdout.rstrip("\n")

    def capture(self) -> str:
        # A float can exist before it is drawn: two identical captures in a
        # row is the signal the screen has settled, not a fixed extra sleep.
        current = self._grab()
        for _ in range(6):
            time.sleep(0.25)
            settled = self._grab()
            if settled == current:
                break
            current = settled
        return current

    # -- cleanup -----------------------------------------------------------

    def _kill_matching_rpc(self) -> None:
        try:
            out = subprocess.run(
                ["ps", "-A", "-o", "pid=,args="], capture_output=True, text=True
            ).stdout
        except OSError:
            return
        needle = f"--listen {self.rpc_path}"
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            pid_str, _, args = line.partition(" ")
            if needle in args:
                try:
                    os.kill(int(pid_str), signal.SIGTERM)
                except (ValueError, OSError):
                    pass

    def cleanup(self) -> None:
        if self.keep:
            return

        # A server-type DAP adapter (julia, js-debug's headless Chrome) is
        # started detached, in its own process group, so it survives the
        # pane dying -- snapshot descendants before kill-server, since
        # afterwards they are reparented to init with nothing tying them
        # back to this run.
        descendants: list[int] = []
        try:
            result = self._tmux("display-message", "-p", "#{pane_pid}")
            pane_pid = int(result.stdout.strip())
            descendants = collect_descendants(pane_pid)
        except (ValueError, OSError):
            pass

        self._tmux("kill-server")
        if self._nvim is not None:
            try:
                self._nvim.close()
            except Exception:
                pass
        # Belt and braces: kill-server does not reliably take Neovim itself
        # down. The RPC path is unique to this process, so this can only
        # match our own Neovim.
        self._kill_matching_rpc()

        for pid in descendants:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        if descendants:
            time.sleep(0.3)
            for pid in descendants:
                try:
                    os.kill(pid, 0)
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

        tmux_tmpdir = os.environ.get("TMUX_TMPDIR", "/tmp")
        try:
            (Path(tmux_tmpdir) / f"tmux-{os.getuid()}" / self.socket).unlink(missing_ok=True)
        except OSError:
            pass
        self.rpc_path.unlink(missing_ok=True)

    def __enter__(self) -> "NvimDriver":
        self.start()
        return self

    def __exit__(self, *exc) -> None:
        self.cleanup()


def drive(
    batches: Sequence[str],
    **kwargs,
) -> str:
    """One-shot: start, send every batch, capture, clean up. Returns the
    captured pane text."""
    with NvimDriver(**kwargs) as driver:
        for batch in batches:
            wait_for = driver.send_batch(batch)
            time.sleep(wait_for)
        return driver.capture()


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", dest="config_dir")
    parser.add_argument("-n", dest="appname")
    parser.add_argument("-d", dest="workdir")
    parser.add_argument("-s", dest="socket")
    parser.add_argument("-W", dest="cols", type=int, default=120)
    parser.add_argument("-H", dest="rows", type=int, default=40)
    parser.add_argument("-w", dest="boot_wait", type=float, default=3)
    parser.add_argument("-p", dest="key_wait", type=float, default=1)
    parser.add_argument("-a", dest="open_file")
    parser.add_argument("-o", dest="outfile")
    parser.add_argument("-e", dest="capture_ansi", action="store_true")
    parser.add_argument("-k", dest="keep", action="store_true")
    parser.add_argument("-t", dest="trust", action="store_true")
    parser.add_argument("-F", dest="force_trust", action="store_true")
    parser.add_argument("-I", dest="no_shada", action="store_true")
    parser.add_argument("batches", nargs="*")
    args = parser.parse_args()

    try:
        capture = drive(
            args.batches,
            config_dir=args.config_dir,
            appname=args.appname,
            workdir=args.workdir,
            socket=args.socket,
            cols=args.cols,
            rows=args.rows,
            boot_wait=args.boot_wait,
            key_wait=args.key_wait,
            capture_ansi=args.capture_ansi,
            keep=args.keep,
            open_file=args.open_file,
            trust=args.trust,
            force_trust=args.force_trust,
            no_shada=args.no_shada,
        )
    except TimeoutError as exc:
        print(exc, file=sys.stderr)
        return 1

    print(capture)
    if args.outfile:
        Path(args.outfile).write_text(capture + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
