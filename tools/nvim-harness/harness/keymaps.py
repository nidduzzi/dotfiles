"""Keymap comparisons check-keymaps.sh drives: collisions against a stock
LazyVim baseline (keymap-collisions.py) and duplicates inside this config's
own source (duplicate-keys.py). Both stay real, standalone top-level scripts
(still invoked directly by CI) -- loaded here by file path rather than
re-implemented, so there is exactly one copy of each algorithm.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
from pathlib import Path
from types import ModuleType

HARNESS_DIR = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, HARNESS_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


_collisions = _load("_keymap_collisions", "keymap-collisions.py")
_duplicates = _load("_duplicate_keys", "duplicate-keys.py")


def _run_with_argv(main, argv: list[str]) -> tuple[int, str]:
    before = sys.argv
    sys.argv = argv
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            status = main()
    finally:
        sys.argv = before
    return status, buf.getvalue()


def check_collisions(baseline_json: str, current_json: str, expected: str, quiet: bool = True) -> tuple[int, str]:
    argv = ["keymap-collisions.py", baseline_json, current_json, "--expected", expected]
    if quiet:
        argv.append("--quiet")
    return _run_with_argv(_collisions.main, argv)


def check_duplicates(lua_dir: str) -> tuple[int, str]:
    return _run_with_argv(_duplicates.main, ["duplicate-keys.py", lua_dir])
