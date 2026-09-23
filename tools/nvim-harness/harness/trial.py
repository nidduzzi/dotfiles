"""Open the branch's editor in a project, without touching ~/.config/nvim.
Replaces try.sh.

Usage:
    python3 -m harness.trial [DIR] [nvim args ...]
"""
from __future__ import annotations

import os
import sys
from pathlib import Path


def _cli(argv: list[str]) -> int:
    config_dir = os.environ.get("NVIM_TOUR_CONFIG", str(Path.home() / "dotfiles" / ".worktrees" / "cfg"))
    appname = os.environ.get("NVIM_TOUR_APPNAME", "nvim-lazyvim")

    if not (Path(config_dir) / appname).is_dir():
        print(f"No configuration at {config_dir}/{appname}.", file=sys.stderr)
        print("Point NVIM_TOUR_CONFIG at the directory holding it, or make the link:", file=sys.stderr)
        print(f"  mkdir -p {config_dir} && ln -s <the worktree> {config_dir}/{appname}", file=sys.stderr)
        return 2

    where = argv[0] if argv else os.getcwd()
    nvim_args = argv[1:] if argv else []

    os.chdir(where)
    env = os.environ.copy()
    env["XDG_CONFIG_HOME"] = config_dir
    env["NVIM_APPNAME"] = appname
    os.execvpe("nvim", ["nvim", *nvim_args], env)


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
