#!/usr/bin/env python3
"""Render a tmux `capture-pane -e` dump as an HTML page.

The page is a faithful terminal picture: a monospace grid with the same
foreground, background, bold, italic, underline and reverse-video attributes
the pane had. Point a browser at the result to get a screenshot of what
Neovim actually drew, which plain text capture cannot show.

Usage:
    ansi-to-html.py INPUT.ansi OUTPUT.html [--title TITLE] [--font-size PX]

Only the SGR (`ESC [ ... m`) sequences tmux emits are interpreted. Other
escape sequences are dropped rather than printed, so they never appear as
stray characters in the picture.
"""

from __future__ import annotations

import argparse
import html
import re
import sys

# The 16 ANSI colours, in tokyonight-ish tones so the picture reads the same
# way the real terminal does.
BASE_COLOURS = [
    "#15161e", "#f7768e", "#9ece6a", "#e0af68",
    "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
    "#414868", "#ff899d", "#9fe044", "#faba4a",
    "#8db0ff", "#c7a9ff", "#a4daff", "#c0caf5",
]

DEFAULT_FG = "#c0caf5"
DEFAULT_BG = "#1a1b26"

SGR_RE = re.compile(r"\x1b\[([0-9;:]*)m")
OTHER_ESC_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[\[\]P][0-9;:?]*[a-zA-Z]|\x1b.")


def cube_colour(index: int) -> str:
    """Map a 256-colour palette index to a hex string."""
    if index < 16:
        return BASE_COLOURS[index]
    if index < 232:
        index -= 16
        levels = [0, 95, 135, 175, 215, 255]
        r = levels[index // 36]
        g = levels[(index % 36) // 6]
        b = levels[index % 6]
        return f"#{r:02x}{g:02x}{b:02x}"
    grey = 8 + (index - 232) * 10
    return f"#{grey:02x}{grey:02x}{grey:02x}"


class Style:
    """The SGR state that applies to the characters being emitted."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.fg: str | None = None
        self.bg: str | None = None
        self.bold = False
        self.dim = False
        self.italic = False
        self.underline = False
        self.reverse = False

    def copy(self) -> "Style":
        clone = Style()
        clone.__dict__.update(self.__dict__)
        return clone

    def css(self) -> str:
        fg = self.fg or DEFAULT_FG
        bg = self.bg or DEFAULT_BG
        if self.reverse:
            fg, bg = bg, fg
        rules = [f"color:{fg}", f"background:{bg}"]
        if self.bold:
            rules.append("font-weight:700")
        if self.dim:
            rules.append("opacity:.65")
        if self.italic:
            rules.append("font-style:italic")
        if self.underline:
            rules.append("text-decoration:underline")
        return ";".join(rules)


def parse_extended(params: list[int], start: int) -> tuple[str | None, int]:
    """Read a 38/48-style extended colour starting at `start`.

    Returns the colour and the index just past the sequence.
    """
    if start >= len(params):
        return None, start
    mode = params[start]
    if mode == 5 and start + 1 < len(params):
        return cube_colour(params[start + 1]), start + 2
    if mode == 2 and start + 3 < len(params):
        r, g, b = params[start + 1 : start + 4]
        return f"#{r:02x}{g:02x}{b:02x}", start + 4
    return None, start + 1


def apply_sgr(style: Style, raw: str) -> None:
    """Fold one SGR parameter string into `style`."""
    if raw in ("", "0"):
        style.reset()
        return

    # Sub-parameters use ':' in some terminals; tmux emits ';'. Flatten both.
    params = [int(p) if p else 0 for p in re.split(r"[;:]", raw)]

    i = 0
    while i < len(params):
        p = params[i]
        if p == 0:
            style.reset()
        elif p == 1:
            style.bold = True
        elif p == 2:
            style.dim = True
        elif p == 3:
            style.italic = True
        elif p == 4:
            style.underline = True
        elif p == 7:
            style.reverse = True
        elif p == 22:
            style.bold = style.dim = False
        elif p == 23:
            style.italic = False
        elif p == 24:
            style.underline = False
        elif p == 27:
            style.reverse = False
        elif 30 <= p <= 37:
            style.fg = BASE_COLOURS[p - 30]
        elif p == 38:
            style.fg, i = parse_extended(params, i + 1)
            continue
        elif p == 39:
            style.fg = None
        elif 40 <= p <= 47:
            style.bg = BASE_COLOURS[p - 40]
        elif p == 48:
            style.bg, i = parse_extended(params, i + 1)
            continue
        elif p == 49:
            style.bg = None
        elif 90 <= p <= 97:
            style.fg = BASE_COLOURS[p - 90 + 8]
        elif 100 <= p <= 107:
            style.bg = BASE_COLOURS[p - 100 + 8]
        i += 1


def render_line(line: str, style: Style) -> str:
    """Turn one captured line into spans, carrying `style` across lines."""
    out: list[str] = []
    pos = 0
    for match in SGR_RE.finditer(line):
        chunk = line[pos : match.start()]
        if chunk:
            out.append(f'<span style="{style.css()}">{html.escape(chunk)}</span>')
        apply_sgr(style, match.group(1))
        pos = match.end()
    tail = line[pos:]
    if tail:
        out.append(f'<span style="{style.css()}">{html.escape(tail)}</span>')
    return "".join(out) or "&nbsp;"


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{
    margin: 0;
    padding: 16px;
    background: {bg};
    font-family: "JetBrainsMono Nerd Font", "FiraCode Nerd Font",
                 "DejaVu Sans Mono", monospace;
    font-size: {font_size}px;
    line-height: 1.25;
  }}
  pre {{
    margin: 0;
    color: {fg};
    white-space: pre;
    display: inline-block;
  }}
</style>
</head>
<body><pre>{body}</pre></body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--title", default="nvim capture")
    parser.add_argument("--font-size", type=int, default=15)
    args = parser.parse_args()

    with open(args.input, encoding="utf-8", errors="replace") as handle:
        raw = handle.read()

    # Drop escape sequences that are not SGR, so they do not leak as text.
    raw = OTHER_ESC_RE.sub(lambda m: m.group(0) if SGR_RE.fullmatch(m.group(0)) else "", raw)

    style = Style()
    lines = [render_line(line, style) for line in raw.split("\n")]

    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(
            PAGE.format(
                title=html.escape(args.title),
                body="\n".join(lines),
                bg=DEFAULT_BG,
                fg=DEFAULT_FG,
                font_size=args.font_size,
            )
        )

    print(f"wrote {args.output} ({len(lines)} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
