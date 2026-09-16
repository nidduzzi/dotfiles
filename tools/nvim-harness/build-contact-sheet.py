#!/usr/bin/env python3
"""Assemble captured panes into one page, so a whole config can be reviewed at once.

Each capture is rendered with the same converter that ansi-to-html.py uses, and
the results are stacked with their labels. Reviewing twenty features then costs
one page rather than twenty files.

Usage:
    build-contact-sheet.py --out PAGE.html --dir CAPTURE_DIR [--title TITLE] \
        "name|description" ...
"""

from __future__ import annotations

import argparse
import html
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Reuse the renderer rather than keeping a second copy of the escape parsing.
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "ansi_to_html", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ansi-to-html.py")
)
assert _spec and _spec.loader
ansi_to_html = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ansi_to_html)


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  :root {{
    color-scheme: dark;
    --bg: #16161e;
    --panel: #1a1b26;
    --ink: #c0caf5;
    --muted: #7f87b0;
    --rule: #2c2f45;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 32px 16px 64px;
    background: var(--bg);
    color: var(--ink);
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    line-height: 1.5;
  }}
  header {{
    max-width: 1180px;
    margin: 0 auto 28px;
  }}
  h1 {{
    margin: 0 0 6px;
    font-size: 1.6rem;
    letter-spacing: -0.01em;
  }}
  .count {{ color: var(--muted); font-size: .95rem; }}
  .shot {{
    max-width: 1180px;
    margin: 0 auto 26px;
    border: 1px solid var(--rule);
    border-radius: 10px;
    overflow: hidden;
    background: var(--panel);
  }}
  .label {{
    display: flex;
    gap: 12px;
    align-items: baseline;
    flex-wrap: wrap;
    padding: 10px 14px;
    border-bottom: 1px solid var(--rule);
    background: #1e2030;
  }}
  .name {{
    font-family: ui-monospace, "JetBrainsMono Nerd Font", monospace;
    font-weight: 700;
    font-size: .95rem;
  }}
  .desc {{ color: var(--muted); font-size: .9rem; }}
  .pane {{ overflow-x: auto; padding: 10px 12px; }}
  pre {{
    margin: 0;
    white-space: pre;
    font-family: "JetBrainsMono Nerd Font", "FiraCode Nerd Font",
                 "DejaVu Sans Mono", ui-monospace, monospace;
    font-size: 12.5px;
    line-height: 1.22;
    display: inline-block;
  }}
  .missing {{ padding: 14px; color: #f7768e; font-size: .9rem; }}
  @media (max-width: 700px) {{
    body {{ padding: 20px 8px 40px; }}
    pre {{ font-size: 10px; }}
  }}
</style>
</head>
<body>
<header>
  <h1>{title}</h1>
  <div class="count">{count} captures</div>
</header>
{body}
</body>
</html>
"""


def render_capture(path: str) -> str:
    """Render one .ansi capture as styled spans."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        raw = handle.read()

    raw = ansi_to_html.OTHER_ESC_RE.sub(
        lambda m: m.group(0) if ansi_to_html.SGR_RE.fullmatch(m.group(0)) else "", raw
    )

    style = ansi_to_html.Style()
    lines = [ansi_to_html.render_line(line, style) for line in raw.split("\n")]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--title", default="Neovim feature tour")
    parser.add_argument("captures", nargs="*", help='"name|description" pairs')
    args = parser.parse_args()

    blocks = []
    for entry in args.captures:
        name, _, desc = entry.partition("|")
        path = os.path.join(args.dir, f"{name}.ansi")

        label = (
            f'<div class="label"><span class="name">{html.escape(name)}</span>'
            f'<span class="desc">{html.escape(desc)}</span></div>'
        )

        if not os.path.exists(path):
            blocks.append(f'<section class="shot">{label}<div class="missing">no capture</div></section>')
            continue

        body = render_capture(path)
        blocks.append(
            f'<section class="shot">{label}<div class="pane"><pre>{body}</pre></div></section>'
        )

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(
            PAGE.format(
                title=html.escape(args.title),
                count=len(blocks),
                body="\n".join(blocks),
            )
        )

    print(f"wrote {args.out} with {len(blocks)} capture(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
