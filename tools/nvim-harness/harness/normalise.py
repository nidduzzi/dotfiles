"""Take the parts of a captured screen that differ between machines out.
Ported from screen-normalise.py so screens.py can call it directly rather
than shelling out.
"""
from __future__ import annotations

import re

MODES = "NORMAL|INSERT|VISUAL|V-LINE|V-BLOCK|COMMAND|TERMINAL|REPLACE|SELECT"
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def normalise_line(line: str, projects: list[str], configs: list[str], branch: str) -> str:
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
    # A Nerd Font glyph followed by a count that differs between machines.
    line = re.sub("\uf487 *\\d+", "", line)

    if "Loading workspace" in line:
        return ""
    if re.search(r"\d+%", line) and "lua_ls" in line:
        return ""

    # The showcmd area holds whatever keys are half-typed at capture time,
    # which depends on how fast the machine delivered them.
    if re.search(f" ({MODES}) ", line):
        line = re.sub(r"<[0-9a-fA-F]{2}>", "", line)
        line = re.sub(r" +", " ", line)

    # A picker titled after the project is as wide as the project's path,
    # replaced before this runs -- the flanking rule still varies by where
    # the checkout lives even though the text says PROJECT either way.
    if re.search(r"╭.*(PROJECT|CONFIG|BRANCH).*╮", line):
        line = re.sub("─{2,}", "─", line)

    if branch:
        line = re.sub(rf"\b{re.escape(branch)}\b", "BRANCH", line)

    return line.rstrip()


def normalise(text: str, projects: list[str], configs: list[str], branch: str) -> str:
    # Longest first, so a path that is a prefix of another does not replace
    # half of it and leave the rest.
    projects = sorted((p for p in projects if p), key=len, reverse=True)
    configs = sorted((c for c in configs if c), key=len, reverse=True)
    return "\n".join(normalise_line(ln, projects, configs, branch) for ln in text.splitlines())
