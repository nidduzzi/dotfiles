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
import re
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
  {font_face}
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
  .section {{
    max-width: 1180px;
    margin: 36px auto 14px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--rule);
    font-size: 1.05rem;
    letter-spacing: .04em;
    text-transform: uppercase;
    color: #7dcfff;
  }}
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
    font-family: "TourMono", "MesloLGL Nerd Font Mono", "JetBrainsMono Nerd Font",
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
  <div class="count">{count} captures &middot; {subtitle}</div>
  <div class="toc">{toc}</div>
</header>
{body}
</body>
</html>
"""


ARTIFACT_PAGE = """<title>{title}</title>
<style>
  {font_face}
  /* The subject is a terminal, so the page commits to one dark world rather
     than trying to look like a document in two themes. Every colour is painted
     explicitly, so it holds on whatever ground the viewer's theme paints. */
  :root {{
    --bg: #13141c;
    --panel: #1a1b26;
    --panel-head: #1e2030;
    --ink: #c8d3f5;
    --muted: #7a82ab;
    --rule: #2b2e43;
    --accent: #7dcfff;
    --accent-dim: #3d5a75;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding-block: 40px 72px;
    padding-inline: 16px;
    background: var(--bg);
    color: var(--ink);
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
  }}
  .wrap {{ max-width: 1200px; margin: 0 auto; }}
  header {{ margin-bottom: 8px; }}
  h1 {{
    margin: 0 0 8px;
    font-size: clamp(1.5rem, 1.1rem + 1.6vw, 2.1rem);
    letter-spacing: -0.02em;
    text-wrap: balance;
  }}
  .lede {{ color: var(--muted); margin: 0 0 4px; max-width: 62ch; }}
  .meta {{
    color: var(--accent-dim);
    font-size: .85rem;
    letter-spacing: .06em;
    text-transform: uppercase;
    font-variant-numeric: tabular-nums;
  }}
  nav.toc {{
    display: flex;
    flex-wrap: wrap;
    gap: 8px 10px;
    margin: 24px 0 8px;
    padding-block: 16px;
    border-top: 1px solid var(--rule);
    border-bottom: 1px solid var(--rule);
  }}
  nav.toc a {{
    color: var(--accent);
    text-decoration: none;
    font-size: .85rem;
    padding: 3px 10px;
    border: 1px solid var(--accent-dim);
    border-radius: 999px;
  }}
  nav.toc a:hover, nav.toc a:focus-visible {{ background: var(--panel-head); }}
  h2.section {{
    margin: 44px 0 16px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--rule);
    font-size: .95rem;
    letter-spacing: .1em;
    text-transform: uppercase;
    color: var(--accent);
    scroll-margin-top: 16px;
  }}
  .shot {{
    margin: 0 0 22px;
    border: 1px solid var(--rule);
    border-radius: 8px;
    overflow: hidden;
    background: var(--panel);
  }}
  .label {{
    display: flex;
    gap: 12px;
    align-items: baseline;
    flex-wrap: wrap;
    padding: 9px 14px;
    border-bottom: 1px solid var(--rule);
    background: var(--panel-head);
  }}
  .name {{
    font-family: "TourMono", ui-monospace, monospace;
    font-weight: 700;
    font-size: .9rem;
    color: var(--accent);
  }}
  .desc {{ color: var(--muted); font-size: .88rem; }}
  .keys {{
    font-family: "TourMono", ui-monospace, monospace;
    font-size: .78rem;
    color: var(--bg);
    background: var(--accent);
    border-radius: 4px;
    padding: 2px 7px;
    white-space: nowrap;
  }}
  .file .label {{ background: #232742; }}
  pre.source {{
    color: var(--ink);
    font-size: 12.5px;
    line-height: 1.5;
  }}
  .pane {{ overflow-x: auto; padding: 10px 12px; }}
  pre {{
    margin: 0;
    white-space: pre;
    font-family: "TourMono", "MesloLGL Nerd Font Mono", "DejaVu Sans Mono", ui-monospace, monospace;
    font-size: 12px;
    line-height: 1.24;
    display: inline-block;
  }}
  .missing {{ padding: 14px; color: #ff757f; font-size: .9rem; }}
  a:focus-visible, nav.toc a:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
  @media (max-width: 640px) {{
    body {{ padding-block: 24px 48px; }}
    pre {{ font-size: 9.5px; }}
  }}
</style>
<div class="wrap">
<header>
  <h1>{title}</h1>
  <p class="lede">{subtitle}</p>
  <p class="meta">{count} captures</p>
</header>
<nav class="toc">{toc}</nav>
{body}
</div>
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
    parser.add_argument(
        "--font-url",
        help="URL or path the page should load a Nerd Font from, so that file-type "
        "glyphs render as icons rather than as empty boxes.",
    )
    parser.add_argument("--subtitle", default="")
    parser.add_argument(
        "--artifact",
        action="store_true",
        help="Emit a page for publishing as an Artifact: no document skeleton, "
        "since the platform supplies one.",
    )
    parser.add_argument("captures", nargs="*", help='"name|description" pairs')
    args = parser.parse_args()

    blocks = []
    sections: list[tuple[str, str]] = []
    for entry in args.captures:
        # "##|Heading" starts a section rather than describing a capture.
        if entry.startswith("##|"):
            heading = entry[3:]
            slug = re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")
            sections.append((slug, heading))
            blocks.append(f'<h2 class="section" id="{slug}">{html.escape(heading)}</h2>')
            continue

        # "FILE|caption|path" embeds a file's contents instead of a capture,
        # for the times the point is what a file says, not what a pane drew.
        if entry.startswith("FILE|"):
            _, caption, file_path = entry.split("|", 2)
            try:
                with open(file_path, encoding="utf-8") as handle:
                    contents = handle.read().rstrip("\n")
            except OSError as exc:
                contents = f"could not read {file_path}: {exc}"
            blocks.append(
                '<section class="shot file">'
                f'<div class="label"><span class="name">{html.escape(os.path.basename(file_path))}</span>'
                f'<span class="desc">{html.escape(caption)}</span></div>'
                f'<div class="pane"><pre class="source">{html.escape(contents)}</pre></div>'
                "</section>"
            )
            continue

        parts = entry.split("|")
        name = parts[0]
        desc = parts[1] if len(parts) > 1 else ""
        keys = parts[2] if len(parts) > 2 else ""
        path = os.path.join(args.dir, f"{name}.ansi")

        keys_html = (
            f'<span class="keys">{html.escape(keys)}</span>' if keys else ""
        )
        label = (
            f'<div class="label"><span class="name">{html.escape(name)}</span>'
            f'{keys_html}'
            f'<span class="desc">{html.escape(desc)}</span></div>'
        )

        if not os.path.exists(path):
            blocks.append(f'<section class="shot">{label}<div class="missing">no capture</div></section>')
            continue

        body = render_capture(path)
        blocks.append(
            f'<section class="shot">{label}<div class="pane"><pre>{body}</pre></div></section>'
        )

    template = ARTIFACT_PAGE if args.artifact else PAGE
    toc = "".join(
        f'<a href="#{slug}">{html.escape(name)}</a>' for slug, name in sections
    )

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(
            template.format(
                toc=toc,
                title=html.escape(args.title),
                subtitle=html.escape(args.subtitle),
                count=sum(1 for b in blocks if "shot" in b[:40]),
                body="\n".join(blocks),
                font_face=(
                    "@font-face {{ font-family: 'TourMono'; src: url('{}') format('truetype');"
                    " font-display: swap; }}".format(args.font_url)
                    if args.font_url
                    else ""
                ),
            )
        )

    print(f"wrote {args.out} with {len(blocks)} capture(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
