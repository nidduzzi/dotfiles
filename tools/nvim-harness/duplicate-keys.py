#!/usr/bin/env python3
"""Find keys this config binds more than once.

lazy.nvim keeps one of two specs that bind the same key and says nothing, so a
duplicate is a mapping that exists in the source and not in the editor.

Only bindings count. A key written down as a label — the capability list names
the key that runs each feature — is documentation, and counting it produced
eight false positives the first time this ran.

Usage:
    duplicate-keys.py CONFIG_LUA_DIR
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# A lazy.nvim key spec, in its two shapes. These must not overlap: an earlier
# version matched `{` on one line and the key on the next, counting a single
# declaration twice and reporting fifteen duplicates that did not exist.
# `\s` matches newlines, so an earlier version spanned `{` on one line and the
# key on the next, which is one declaration and was counted as two.
SPEC_SAME_LINE = re.compile(r'^[ \t]*\{[ \t]*"((?:<leader>|<[A-Za-z-]+>)[^"]*)"', re.M)
SPEC_OWN_LINE = re.compile(r'^[ \t]*"((?:<leader>|<[A-Za-z-]+>)[^"]*)"[ \t]*,[ \t]*$', re.M)

# vim.keymap.set / map("n", "<leader>x", ...)
MAP_CALL = re.compile(
    r'(?:vim\.keymap\.set|\bmap)\(\s*(?:\{[^}]*\}|"[a-z]+")\s*,\s*"([^"]+)"'
)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    root = Path(sys.argv[1])
    seen: dict[str, list[str]] = {}

    for path in sorted(root.rglob("*.lua")):
        # The capability list writes keys down to show them, not to bind them.
        if path.name == "capabilities.lua":
            continue

        text = path.read_text(encoding="utf-8")

        for pattern in (SPEC_SAME_LINE, SPEC_OWN_LINE, MAP_CALL):
            for match in pattern.finditer(text):
                key = match.group(1)
                line = text[: match.start()].count("\n") + 1
                seen.setdefault(key, []).append(f"{path.name}:{line}")

    duplicates = {key: places for key, places in seen.items() if len(set(places)) > 1}

    if not duplicates:
        print("none")
        return 0

    for key, places in sorted(duplicates.items()):
        print(f"{key:<24} {', '.join(sorted(set(places)))}")

    return 1


if __name__ == "__main__":
    sys.exit(main())
