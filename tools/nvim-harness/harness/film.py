"""Record a feature as a sequence of frames, one per keystroke, with the key
that produced each -- a short film rather than a single screenshot.

Run one at a time. Two recordings sharing an NVIM_APPNAME share Neovim's
swap and shada, and the second opens a file the first still holds.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from .driver import NvimDriver


class FilmDriver(NvimDriver):
    """NvimDriver plus per-batch frame capture and a `slow:` batch form that
    polls the agent instead of sleeping a fixed amount."""

    def __init__(self, *, out: str, title: str = "Neovim", slow_wait: float | None = None, **kwargs) -> None:
        kwargs.setdefault("capture_ansi", True)
        kwargs.setdefault("key_wait", 1.5)
        kwargs.setdefault("boot_wait", 60)
        super().__init__(**kwargs)
        self.out = Path(out)
        self.title = title
        self.slow_wait = slow_wait if slow_wait is not None else self.key_wait
        self._frame = 0

    def start(self) -> None:
        self.out.mkdir(parents=True, exist_ok=True)
        for f in self.out.glob("frame-*.ansi"):
            f.unlink()
        (self.out / "frames.tsv").unlink(missing_ok=True)
        super().start()

    def _capture_frame(self, label: str) -> None:
        text = self._grab()
        path = self.out / f"frame-{self._frame:03d}.ansi"
        path.write_text(text + "\n")
        with open(self.out / "frames.tsv", "a") as f:
            f.write(f"{path.name}\t{label}\n")
        self._frame += 1

    def await_agent(self) -> None:
        # Polled over RPC rather than slept: a fixed pause was wrong in both
        # directions -- a local model answering in 151s against a 150s cap,
        # and every faster answer sitting idle for the rest of it.
        deadline = time.monotonic() + self.slow_wait + 1
        # A request that has not started yet also reports "not running" --
        # give it a moment before asking.
        time.sleep(2)
        while time.monotonic() < deadline:
            try:
                running = self._nvim.exec_lua(
                    'local ok, agent = pcall(require, "util.agent")'
                    ' return ok and agent.is_running() or false'
                )
            except Exception:
                running = False
            if not running:
                break
            time.sleep(1)
        time.sleep(1.5)

    def record(self, batches: list[str]) -> int:
        self._capture_frame("before")
        for batch in batches:
            slow = batch.startswith("slow:")
            if slow:
                batch = batch[len("slow:"):]

            if batch.startswith("wait:"):
                rest = batch[len("wait:"):]
                wait_str, _, batch = rest.partition(":")
                wait_for = float(wait_str)
            else:
                wait_for = self.key_wait

            if batch.startswith("ex:"):
                self.run_ex(batch[len("ex:"):])
                label = f":{batch[len('ex:'):]}"
            elif batch.startswith("keys:"):
                tokens = batch[len("keys:"):].split()
                self.send_keys(tokens)
                label = batch[len("keys:"):]
            else:
                self.send_keys([batch])
                label = batch

            if slow:
                self.await_agent()
            else:
                time.sleep(wait_for)
            self._capture_frame(label)

        (self.out / "title.txt").write_text(self.title + "\n")
        return self._frame


def record(batches: list[str], **kwargs) -> int:
    with FilmDriver(**kwargs) as driver:
        return driver.record(batches)


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", dest="config_dir")
    parser.add_argument("-n", dest="appname")
    parser.add_argument("-d", dest="workdir")
    parser.add_argument("-o", dest="out", required=True)
    parser.add_argument("-W", dest="cols", type=int, default=120)
    parser.add_argument("-H", dest="rows", type=int, default=34)
    parser.add_argument("-w", dest="boot_wait", type=float, default=60)
    parser.add_argument("-p", dest="key_wait", type=float, default=1.5)
    parser.add_argument("-P", dest="slow_wait", type=float)
    parser.add_argument("-T", dest="title", default="Neovim")
    parser.add_argument("-t", dest="trust", action="store_true")
    parser.add_argument("-F", dest="force_trust", action="store_true")
    parser.add_argument("-I", dest="no_shada", action="store_true")
    parser.add_argument("batches", nargs="*")
    args = parser.parse_args()

    try:
        n = record(
            args.batches,
            config_dir=args.config_dir,
            appname=args.appname,
            workdir=args.workdir,
            out=args.out,
            cols=args.cols,
            rows=args.rows,
            boot_wait=args.boot_wait,
            key_wait=args.key_wait,
            slow_wait=args.slow_wait,
            title=args.title,
            trust=args.trust,
            force_trust=args.force_trust,
            no_shada=args.no_shada,
        )
    except TimeoutError as exc:
        print(exc, file=sys.stderr)
        return 1

    print(f"{n} frames in {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
