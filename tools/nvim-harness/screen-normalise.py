#!/usr/bin/env python3
"""Take the parts of a captured screen that differ between two machines out.

This was a sed script, and sed is where portability goes to argue: `\\b`, `\\|`
and `\\{n,\\}` are GNU extensions, and macOS ships the BSD one. There the
branch name was never replaced and the statusline never collapsed, so every
screen "differed" for reasons that had nothing to do with the editor.

Usage:
    screen-normalise.py [--project DIR ...] [--config DIR ...] [--branch NAME]

Reads a captured screen on stdin, writes the normalised one on stdout.
"""

from __future__ import annotations

import argparse
import re
import sys

MODES = "NORMAL|INSERT|VISUAL|V-LINE|V-BLOCK|COMMAND|TERMINAL|REPLACE|SELECT"
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def normalise(line: str, projects: list[str], configs: list[str], branch: str) -> str:
    for path in projects:
        line = line.replace(path, "PROJECT")
    for path in configs:
        line = line.replace(path, "CONFIG")

    line = re.sub(r"\d\d:\d\d *$", "HH:MM", line)
    line = re.sub(r" in \d+\.\d+ms", " in DURATIONms", line)
    line = re.sub(r" in \d+ms", " in DURATIONms", line)
    line = re.sub(r"\d+\.\d+ms", "DURATIONms", line)
    line = re.sub(r"\d+/\d+ plugins", "N/N plugins", line)
    line = re.sub(r"/home/[a-z0-9_-]*", "~", line)
    line = re.sub(f"[{SPINNER}]", "SPINNER", line)
    line = re.sub(r"(\d+)/\d+ │", r"\1/TOTAL │", line)
    # The glyph is a Nerd Font one, and what follows it is a count that
    # differs between machines. Written as an escape because it is invisible
    # in most editors and was read as a plain space once already, which
    # stripped every line number on the screen.
    line = re.sub("\uf487 *\\d+", "", line)

    if "Loading workspace" in line:
        return ""
    if re.search(r"\d+%", line) and "lua_ls" in line:
        return ""

    # The showcmd area holds whatever keys are half-typed at the moment of
    # capture, which depends on how fast the machine delivered them.
    if re.search(f" ({MODES}) ", line):
        line = re.sub(r"<[0-9a-fA-F]{2}>", "", line)
        line = re.sub(r" +", " ", line)

    # A picker titled after the project is as wide as that project's path, and
    # the path is replaced before this runs -- so the title's flanking rule
    # varies by where the checkout happens to live while the text says PROJECT
    # either way.
    if re.search(r"╭.*(PROJECT|CONFIG|BRANCH).*╮", line):
        line = re.sub("─{2,}", "─", line)

    if branch:
        line = re.sub(rf"\b{re.escape(branch)}\b", "BRANCH", line)

    return line.rstrip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", action="append", default=[])
    parser.add_argument("--config", action="append", default=[])
    parser.add_argument("--branch", default="")
    arguments = parser.parse_args()

    # Longest first, so a path that is a prefix of another does not replace
    # half of it and leave the rest.
    projects = sorted((path for path in arguments.project if path), key=len, reverse=True)
    configs = sorted((path for path in arguments.config if path), key=len, reverse=True)

    for line in sys.stdin:
        print(normalise(line.rstrip("\n"), projects, configs, arguments.branch))
    return 0


if __name__ == "__main__":
    sys.exit(main())
