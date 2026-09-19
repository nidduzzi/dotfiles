#!/usr/bin/env python3
"""Check that the canary proves the flags the editor actually sends.

agent-canary.sh asserts a tool registry for each rung. lua/util/agent/
backends.lua decides the flags each rung runs with. They are two files, and a
guarantee that describes flags nobody sends is not a guarantee.

Exit status is 1 when they disagree.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BACKENDS = HERE / "../../.worktrees/nvim-lazyvim/lua/util/agent/backends.lua"
CANARY = HERE / "agent-canary.sh"

RUNGS = ("chat", "context", "explore", "edit")


def flags_from_backends(text: str) -> dict[str, list[str]]:
    block = re.search(r"M\.claude = \{(.*?)\n\}", text, re.S)
    if not block:
        sys.exit("Could not find M.claude in backends.lua")

    rungs = re.search(r"rungs = \{(.*?)\n  \}", block.group(1), re.S)
    if not rungs:
        sys.exit("Could not find claude's rungs in backends.lua")

    found: dict[str, list[str]] = {}
    for name, body in re.findall(r"(\w+) = \{(.*?)\}", rungs.group(1), re.S):
        found[name] = re.findall(r'"([^"]*)"', body)
    return found


def flags_from_canary(text: str) -> dict[str, list[str]]:
    block = re.search(r"claude_flags\(\) \{(.*?)\n\}", text, re.S)
    if not block:
        sys.exit("Could not find claude_flags in agent-canary.sh")

    found: dict[str, list[str]] = {}
    for names, body in re.findall(r"^\s*([\w|]+)\)\s*printf[^\n]*?--tools([^;]*);;", block.group(1), re.M):
        tools = re.search(r'"([^"]*)"|(\S+)', body.strip())
        value = (tools.group(1) if tools.group(1) is not None else tools.group(2)) if tools else ""
        strict = "--strict-mcp-config" in body
        flags = ["--tools", value] + (["--strict-mcp-config"] if strict else [])
        for name in names.split("|"):
            found[name] = flags
    return found


def main() -> int:
    if not BACKENDS.exists():
        sys.exit(f"No backends.lua at {BACKENDS}")

    editor = flags_from_backends(BACKENDS.read_text())
    canary = flags_from_canary(CANARY.read_text())

    problems = []
    for rung in RUNGS:
        if rung not in editor:
            problems.append(f"{rung}: backends.lua defines no flags")
            continue
        if rung not in canary:
            problems.append(f"{rung}: agent-canary.sh tests no flags")
            continue
        if editor[rung] != canary[rung]:
            problems.append(
                f"{rung}:\n    editor sends {editor[rung]}\n    canary tests {canary[rung]}"
            )

    for rung in RUNGS:
        print(f"{rung:9} {' '.join(editor.get(rung, ['-']))}")

    if problems:
        print()
        print("The canary does not prove what the editor sends:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print()
    print(f"{len(RUNGS)} rungs: the flags proven are the flags sent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
