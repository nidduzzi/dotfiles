#!/usr/bin/env python3
"""Print the keys each tour scenario presses, in the notation Neovim uses.

The scenarios are written in tmux send-keys notation, which is not what a
person reads in a keymap: `Space` is the leader, `M-d` is `<a-d>`, and a bare
word is text being typed rather than a key. Deriving the readable form from the
scenario list rather than writing it out twice means the two cannot disagree
about what a capture actually shows.

Usage:
    scenario-keys.py [FEATURE_TOUR_SCRIPT] > keys.json
"""

from __future__ import annotations

import json
import re
import sys

# tmux's names for keys, and how a keymap would write them.
SPECIAL = {
    "Space": "<leader>",
    "Enter": "<CR>",
    "Escape": "<Esc>",
    "Tab": "<Tab>",
    "BSpace": "<BS>",
}


def readable(tokens: list[str]) -> str:
    """Turn one scenario's key batches into something readable.

    The result is a recipe to reproduce the capture, not prose: tokens appear in
    the order they are sent, with tmux's names translated to the ones a keymap
    uses. Text typed into a prompt and keys pressed in a list look the same here
    because they are sent the same way, and guessing which is which got `i`,
    the key that focuses the explorer's filter, labelled as typed text.
    """
    out: list[str] = []

    for token in tokens:
        if token in SPECIAL:
            if token == "Space":
                out.append("<leader>")
            else:
                out.append(SPECIAL[token])
            continue

        modifier = re.fullmatch(r"([CM])-(.+)", token)
        if modifier:
            prefix = "c" if modifier.group(1) == "C" else "a"
            out.append(f"<{prefix}-{modifier.group(2)}>")
            continue

        # A short token straight after the leader completes that mapping.
        if out and out[-1] == "<leader>" and len(token) <= 3:
            out[-1] = "<leader>" + token
            continue

        out.append(token)

    return " ".join(out)


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "tools/nvim-harness/feature-tour.sh"
    script = open(path, encoding="utf-8").read()

    keys: dict[str, str] = {}
    for line in re.findall(r'^\s*"([^"]+)"\s*$', script, re.M):
        parts = line.split("|")
        if len(parts) < 3 or parts[0].startswith("#"):
            continue
        name, tokens = parts[0], parts[3:]
        keys[name] = readable([t for t in tokens if t])

    json.dump(keys, sys.stdout, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
