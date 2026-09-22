"""Render captured ANSI panes as HTML: single frames, contact sheets, films,
and multi-film tours. Replaces ansi-to-html.py, build-contact-sheet.py,
build-film.py, build-tour.py, scenario-keys.py -- one ANSI reader, one set of
page templates, instead of the same escape-sequence parsing copied into four
files via importlib.

Usage (each still independently invocable, matching the scripts it replaces):
    python3 -m harness.reporting ansi-to-html INPUT.ansi OUTPUT.html [--title T] [--font-size N]
    python3 -m harness.reporting contact-sheet --out PAGE.html --dir CAPTURE_DIR [--title T] "name|desc" ...
    python3 -m harness.reporting film --dir FRAME_DIR --out PAGE.html [--title T]
    python3 -m harness.reporting tour --dir BASE --out PAGE.html [--title T] [--order a,b,c]
    python3 -m harness.reporting scenario-keys [--script FILE] > keys.json
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

# -- ANSI -> styled spans (was ansi-to-html.py) --------------------------

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


def _parse_extended(params: list[int], start: int) -> tuple[str | None, int]:
    """Read a 38/48-style extended colour starting at `start`."""
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
            style.fg, i = _parse_extended(params, i + 1)
            continue
        elif p == 39:
            style.fg = None
        elif 40 <= p <= 47:
            style.bg = BASE_COLOURS[p - 40]
        elif p == 48:
            style.bg, i = _parse_extended(params, i + 1)
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


def render_capture(path: str | Path) -> str:
    """Render one whole .ansi capture file as styled spans."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        raw = handle.read()
    raw = OTHER_ESC_RE.sub(lambda m: m.group(0) if SGR_RE.fullmatch(m.group(0)) else "", raw)
    style = Style()
    return "\n".join(render_line(line, style) for line in raw.split("\n"))


def _read_frames(folder: Path) -> list[dict] | None:
    """frame-NNN.ansi + frames.tsv, rendered -- shared by film and tour
    pages, which otherwise duplicate this exact loop."""
    listing = folder / "frames.tsv"
    if not listing.exists():
        return None
    frames = []
    for line in listing.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        name, _, key = line.partition("\t")
        path = folder / name
        if not path.exists():
            continue
        raw = path.read_text(encoding="utf-8")
        raw = OTHER_ESC_RE.sub(lambda m: m.group(0) if SGR_RE.fullmatch(m.group(0)) else "", raw)
        # A fresh Style per frame, not carried across: each frame is an
        # independent tmux capture, and its SGR state should not inherit
        # whatever the previous frame's last line happened to leave set.
        # .splitlines(), not .split("\n"): the capture is written with a
        # trailing newline, and split("\n") turns that into a spurious
        # empty final line -- an extra blank frame row that bash's
        # equivalent (which does use .splitlines()) never had.
        style = Style()
        body = "\n".join(render_line(line2, style) for line2 in raw.splitlines())
        frames.append({"html": body, "key": key or "—"})
    return frames or None


ANSI_PAGE = """<!DOCTYPE html>
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


def ansi_to_html(input_path: str | Path, output_path: str | Path, *, title: str = "nvim capture", font_size: int = 15) -> int:
    with open(input_path, encoding="utf-8", errors="replace") as handle:
        raw = handle.read()
    raw = OTHER_ESC_RE.sub(lambda m: m.group(0) if SGR_RE.fullmatch(m.group(0)) else "", raw)
    style = Style()
    lines = [render_line(line, style) for line in raw.split("\n")]
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(
            ANSI_PAGE.format(
                title=html.escape(title), body="\n".join(lines),
                bg=DEFAULT_BG, fg=DEFAULT_FG, font_size=font_size,
            )
        )
    return len(lines)


# -- contact sheet (was build-contact-sheet.py) --------------------------

CONTACT_PAGE = """<!DOCTYPE html>
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


CONTACT_ARTIFACT_PAGE = """<title>{title}</title>
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


def build_contact_sheet(
    *,
    out: str | Path,
    dir: str | Path,
    captures: list[str],
    title: str = "Neovim feature tour",
    subtitle: str = "",
    font_url: str | None = None,
    artifact: bool = False,
) -> int:
    """captures: "name|description" / "name|description|keys" / "##|Heading"
    / "FILE|caption|path" entries, same shape build-contact-sheet.py took."""
    capture_dir = Path(dir)
    blocks = []
    sections: list[tuple[str, str]] = []
    for entry in captures:
        if entry.startswith("##|"):
            heading = entry[3:]
            slug = re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")
            sections.append((slug, heading))
            blocks.append(f'<h2 class="section" id="{slug}">{html.escape(heading)}</h2>')
            continue

        if entry.startswith("FILE|"):
            _, caption, file_path = entry.split("|", 2)
            try:
                contents = Path(file_path).read_text(encoding="utf-8").rstrip("\n")
            except OSError as exc:
                contents = f"could not read {file_path}: {exc}"
            blocks.append(
                '<section class="shot file">'
                f'<div class="label"><span class="name">{html.escape(Path(file_path).name)}</span>'
                f'<span class="desc">{html.escape(caption)}</span></div>'
                f'<div class="pane"><pre class="source">{html.escape(contents)}</pre></div>'
                "</section>"
            )
            continue

        parts = entry.split("|")
        name = parts[0]
        desc = parts[1] if len(parts) > 1 else ""
        keys = parts[2] if len(parts) > 2 else ""
        path = capture_dir / f"{name}.ansi"

        keys_html = f'<span class="keys">{html.escape(keys)}</span>' if keys else ""
        label = (
            f'<div class="label"><span class="name">{html.escape(name)}</span>'
            f'{keys_html}'
            f'<span class="desc">{html.escape(desc)}</span></div>'
        )

        if not path.exists():
            blocks.append(f'<section class="shot">{label}<div class="missing">no capture</div></section>')
            continue

        body = render_capture(path)
        blocks.append(f'<section class="shot">{label}<div class="pane"><pre>{body}</pre></div></section>')

    template = CONTACT_ARTIFACT_PAGE if artifact else CONTACT_PAGE
    toc = "".join(f'<a href="#{slug}">{html.escape(name)}</a>' for slug, name in sections)

    Path(out).write_text(
        template.format(
            toc=toc,
            title=html.escape(title),
            subtitle=html.escape(subtitle),
            count=sum(1 for b in blocks if "shot" in b[:40]),
            body="\n".join(blocks),
            font_face=(
                f"@font-face {{ font-family: 'TourMono'; src: url('{font_url}') format('truetype');"
                " font-display: swap; }}"
                if font_url else ""
            ),
        ),
        encoding="utf-8",
    )
    return len(blocks)


# -- one film (was build-film.py) ----------------------------------------

FILM_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  :root {{
    color-scheme: dark;
    --ground: #11121a;
    --panel: #1a1b26;
    --ink: #c8d3f5;
    --dim: #7a88cf;
    --edge: #2f334d;
    --accent: #82aaff;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 24px 16px 48px;
    background: var(--ground);
    color: var(--ink);
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
  }}
  header {{ max-width: 1100px; margin: 0 auto 20px; }}
  h1 {{ font-size: 1.4rem; margin: 0 0 4px; font-weight: 600; }}
  .sub {{ color: var(--dim); font-size: 0.9rem; margin: 0; }}
  .stage {{
    max-width: 1100px;
    margin: 0 auto;
    background: var(--panel);
    border: 1px solid var(--edge);
    border-radius: 10px;
    overflow: hidden;
  }}
  .screen {{ overflow-x: auto; padding: 14px 16px; }}
  pre {{
    margin: 0;
    white-space: pre;
    display: inline-block;
    font-family: "JetBrainsMono Nerd Font", "FiraCode Nerd Font",
                 "DejaVu Sans Mono", ui-monospace, monospace;
    font-size: {font_size}px;
    line-height: 1.25;
  }}
  .bar {{
    display: flex;
    gap: 12px;
    align-items: center;
    padding: 10px 16px;
    border-top: 1px solid var(--edge);
    flex-wrap: wrap;
  }}
  button {{
    font: inherit;
    color: var(--ink);
    background: #252838;
    border: 1px solid var(--edge);
    border-radius: 6px;
    padding: 5px 12px;
    cursor: pointer;
  }}
  button:hover {{ border-color: var(--accent); }}
  button:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
  input[type=range] {{ flex: 1; min-width: 160px; accent-color: var(--accent); }}
  .key {{
    font-family: ui-monospace, monospace;
    background: #0f1018;
    border: 1px solid var(--edge);
    border-bottom-width: 2px;
    border-radius: 5px;
    padding: 3px 9px;
    color: var(--accent);
    white-space: nowrap;
  }}
  .count {{ color: var(--dim); font-variant-numeric: tabular-nums; font-size: 0.85rem; }}
  .hint {{ max-width: 1100px; margin: 14px auto 0; color: var(--dim); font-size: 0.85rem; }}
</style>
</head>
<body>
<header>
  <h1>{title}</h1>
  <p class="sub">{subtitle}</p>
</header>

<div class="stage">
  <div class="screen"><pre id="screen"></pre></div>
  <div class="bar">
    <button id="play" aria-label="Play or pause">Play</button>
    <button id="prev" aria-label="Previous frame">&larr;</button>
    <button id="next" aria-label="Next frame">&rarr;</button>
    <span class="key" id="key"></span>
    <input type="range" id="scrub" min="0" max="0" value="0" aria-label="Frame">
    <span class="count" id="count"></span>
  </div>
</div>

<p class="hint">Arrow keys step a frame at a time. Space plays and pauses.</p>

<script>
const FRAMES = {frames};
const screen = document.getElementById("screen");
const keyLabel = document.getElementById("key");
const count = document.getElementById("count");
const scrub = document.getElementById("scrub");
const play = document.getElementById("play");

let at = 0;
let timer = null;

scrub.max = String(FRAMES.length - 1);

function show(index) {{
  at = Math.max(0, Math.min(index, FRAMES.length - 1));
  screen.innerHTML = FRAMES[at].html;
  keyLabel.textContent = FRAMES[at].key;
  count.textContent = (at + 1) + " / " + FRAMES.length;
  scrub.value = String(at);
}}

function stop() {{
  if (timer) {{ clearInterval(timer); timer = null; }}
  play.textContent = "Play";
}}

function start() {{
  if (at >= FRAMES.length - 1) show(0);
  play.textContent = "Pause";
  timer = setInterval(() => {{
    if (at >= FRAMES.length - 1) {{ stop(); return; }}
    show(at + 1);
  }}, 1100);
}}

play.addEventListener("click", () => (timer ? stop() : start()));
document.getElementById("prev").addEventListener("click", () => {{ stop(); show(at - 1); }});
document.getElementById("next").addEventListener("click", () => {{ stop(); show(at + 1); }});
scrub.addEventListener("input", () => {{ stop(); show(Number(scrub.value)); }});

document.addEventListener("keydown", (event) => {{
  if (event.key === "ArrowLeft") {{ stop(); show(at - 1); event.preventDefault(); }}
  if (event.key === "ArrowRight") {{ stop(); show(at + 1); event.preventDefault(); }}
  if (event.key === " ") {{ timer ? stop() : start(); event.preventDefault(); }}
}});

show(0);
</script>
</body>
</html>
"""


FILM_ARTIFACT_PAGE = """<title>{title}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>
  :root {{
    --ground: #f3f4fa;
    --panel: #ffffff;
    --ink: #1b1d2b;
    --dim: #5a6285;
    --edge: #dde0ee;
    --accent: #3b5bdb;
    --cap: #eceffa;
    --rail: #e6e9f6;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --ground: #0f1018;
      --panel: #191a24;
      --ink: #ccd3f0;
      --dim: #7d87b4;
      --edge: #2a2d40;
      --accent: #8aa9ff;
      --cap: #151622;
      --rail: #12131d;
    }}
  }}
  :root[data-theme="dark"] {{
    --ground: #0f1018;
    --panel: #191a24;
    --ink: #ccd3f0;
    --dim: #7d87b4;
    --edge: #2a2d40;
    --accent: #8aa9ff;
    --cap: #151622;
    --rail: #12131d;
  }}

  * {{ box-sizing: border-box; }}

  body {{
    margin: 0;
    padding-block: 32px 56px;
    padding-inline: 16px;
    background: var(--ground);
    color: var(--ink);
    font-family: "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif;
    line-height: 1.5;
  }}

  .wrap {{ max-width: 1180px; margin: 0 auto; }}

  .eyebrow {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.72rem;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--dim);
    margin: 0 0 10px;
  }}
  h1 {{
    font-size: clamp(1.5rem, 3.4vw, 2.1rem);
    font-weight: 600;
    letter-spacing: -0.015em;
    margin: 0 0 8px;
    text-wrap: balance;
  }}
  .lede {{ margin: 0 0 26px; color: var(--dim); max-width: 62ch; }}

  .film {{
    background: var(--panel);
    border: 1px solid var(--edge);
    border-radius: 12px;
    overflow: hidden;
  }}
  .screen {{
    overflow-x: auto;
    padding: 14px 16px;
    background: {bg};
  }}
  pre {{
    margin: 0;
    white-space: pre;
    display: inline-block;
    font-family: "IBM Plex Mono", "JetBrainsMono Nerd Font", ui-monospace, monospace;
    font-size: {font_size}px;
    line-height: 1.3;
  }}

  .transport {{
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    border-top: 1px solid var(--edge);
    flex-wrap: wrap;
  }}
  button {{
    font: inherit;
    font-size: 0.86rem;
    color: var(--ink);
    background: var(--cap);
    border: 1px solid var(--edge);
    border-radius: 7px;
    padding: 6px 13px;
    cursor: pointer;
  }}
  button:hover {{ border-color: var(--accent); color: var(--accent); }}
  button:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
  .now {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.85rem;
    color: var(--dim);
    font-variant-numeric: tabular-nums;
    margin-left: auto;
  }}

  /* The filmstrip is the scrubber. The content is a sequence of keystrokes,
     so the navigation is the sequence, each cel labelled with its key. */
  .strip {{
    display: flex;
    gap: 8px;
    overflow-x: auto;
    padding: 12px 16px;
    background: var(--rail);
    border-top: 1px solid var(--edge);
  }}
  .cel {{
    flex: 0 0 auto;
    display: flex;
    flex-direction: column;
    gap: 5px;
    align-items: flex-start;
    background: var(--panel);
    border: 1px solid var(--edge);
    border-radius: 8px;
    padding: 8px 11px;
    cursor: pointer;
    min-width: 96px;
  }}
  .cel:hover {{ border-color: var(--accent); }}
  .cel[aria-current="true"] {{
    border-color: var(--accent);
    box-shadow: inset 0 -2px 0 var(--accent);
  }}
  .cel .n {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.66rem;
    color: var(--dim);
    font-variant-numeric: tabular-nums;
  }}
  .cel .k {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.82rem;
    color: var(--accent);
    white-space: nowrap;
  }}

  .notes {{
    margin: 26px auto 0;
    display: grid;
    gap: 18px;
    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  }}
  .note h2 {{
    font-size: 0.78rem;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--dim);
    margin: 0 0 6px;
    font-weight: 500;
  }}
  .note p {{ margin: 0; font-size: 0.92rem; }}
  code {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.86em;
    background: var(--cap);
    border: 1px solid var(--edge);
    border-radius: 4px;
    padding: 1px 5px;
  }}
  @media (prefers-reduced-motion: reduce) {{
    * {{ transition: none !important; }}
  }}
</style>

<div class="wrap">
  <p class="eyebrow">{eyebrow}</p>
  <h1>{title}</h1>
  <p class="lede">{subtitle}</p>

  <div class="film">
    <div class="screen"><pre id="screen"></pre></div>
    <div class="transport">
      <button id="play">Play</button>
      <button id="prev" aria-label="Previous frame">&larr;</button>
      <button id="next" aria-label="Next frame">&rarr;</button>
      <span class="now"><span id="count"></span> &middot; 120&times;34</span>
    </div>
    <div class="strip" id="strip"></div>
  </div>

  <div class="notes">
    <div class="note">
      <h2>Why frames</h2>
      <p>A screenshot shows where a feature ends up. This shows the path to it &mdash; which key, and what changed because of it.</p>
    </div>
    <div class="note">
      <h2>How it was made</h2>
      <p>Neovim driven in a real terminal, the pane captured as ANSI after every keystroke. No recorder, no video: the frames are text.</p>
    </div>
    <div class="note">
      <h2>Stepping through</h2>
      <p>Click a cel below, use the arrows, or press <code>&larr;</code> and <code>&rarr;</code>. Space plays and pauses.</p>
    </div>
  </div>
</div>

<script>
const FRAMES = {frames};
const screen = document.getElementById("screen");
const strip = document.getElementById("strip");
const count = document.getElementById("count");
const play = document.getElementById("play");

let at = 0;
let timer = null;

FRAMES.forEach((frame, index) => {{
  const cel = document.createElement("button");
  cel.className = "cel";
  cel.type = "button";
  cel.innerHTML = '<span class="n">' + String(index + 1).padStart(2, "0") + '</span>' +
                  '<span class="k"></span>';
  cel.querySelector(".k").textContent = frame.key;
  cel.addEventListener("click", () => {{ stop(); show(index); }});
  strip.appendChild(cel);
}});

const cels = Array.from(strip.children);

function show(index) {{
  at = Math.max(0, Math.min(index, FRAMES.length - 1));
  screen.innerHTML = FRAMES[at].html;
  count.textContent = (at + 1) + " / " + FRAMES.length;
  cels.forEach((cel, i) => cel.setAttribute("aria-current", i === at ? "true" : "false"));
  cels[at].scrollIntoView({{ block: "nearest", inline: "nearest" }});
}}

function stop() {{
  if (timer) {{ clearInterval(timer); timer = null; }}
  play.textContent = "Play";
}}

function start() {{
  if (at >= FRAMES.length - 1) show(0);
  play.textContent = "Pause";
  timer = setInterval(() => {{
    if (at >= FRAMES.length - 1) {{ stop(); return; }}
    show(at + 1);
  }}, 1400);
}}

play.addEventListener("click", () => (timer ? stop() : start()));
document.getElementById("prev").addEventListener("click", () => {{ stop(); show(at - 1); }});
document.getElementById("next").addEventListener("click", () => {{ stop(); show(at + 1); }});

document.addEventListener("keydown", (event) => {{
  if (event.target.closest("button") && event.key === " ") return;
  if (event.key === "ArrowLeft") {{ stop(); show(at - 1); event.preventDefault(); }}
  if (event.key === "ArrowRight") {{ stop(); show(at + 1); event.preventDefault(); }}
  if (event.key === " ") {{ timer ? stop() : start(); event.preventDefault(); }}
}});

show(0);
</script>
"""


def build_film_page(
    *,
    dir: str | Path,
    out: str | Path,
    title: str | None = None,
    subtitle: str = "",
    font_size: int = 13,
    artifact: bool = False,
    eyebrow: str = "Neovim, one frame per keystroke",
) -> int:
    source = Path(dir)
    frames = _read_frames(source)
    if frames is None:
        print(f"No frames.tsv in {source}. Run film.py first.", file=sys.stderr)
        return -1

    if not title:
        named = source / "title.txt"
        title = named.read_text(encoding="utf-8").strip() if named.exists() else "Neovim"

    template = FILM_ARTIFACT_PAGE if artifact else FILM_PAGE
    fields = dict(
        title=html.escape(title),
        subtitle=html.escape(subtitle or f"{len(frames)} frames, one per keystroke"),
        font_size=font_size,
        frames=json.dumps(frames),
    )
    if artifact:
        fields["eyebrow"] = html.escape(eyebrow)
        fields["bg"] = BASE_COLOURS[0]

    out_path = Path(out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(template.format(**fields), encoding="utf-8")
    return len(frames)


# -- a whole tour, several films (was build-tour.py) ---------------------

TOUR_PAGE = """<title>{title}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
<style>
  :root {{
    --ground: #f3f4fa;
    --panel: #ffffff;
    --ink: #1b1d2b;
    --dim: #5a6285;
    --edge: #dde0ee;
    --accent: #3b5bdb;
    --cap: #eceffa;
    --rail: #e9ecf7;
    --screen-bg: #1a1b26;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:not([data-theme="light"]) {{
      --ground: #0f1018;
      --panel: #191a24;
      --ink: #ccd3f0;
      --dim: #7d87b4;
      --edge: #2a2d40;
      --accent: #8aa9ff;
      --cap: #151622;
      --rail: #12131d;
    }}
  }}
  :root[data-theme="dark"] {{
    --ground: #0f1018;
    --panel: #191a24;
    --ink: #ccd3f0;
    --dim: #7d87b4;
    --edge: #2a2d40;
    --accent: #8aa9ff;
    --cap: #151622;
    --rail: #12131d;
  }}

  * {{ box-sizing: border-box; }}

  body {{
    margin: 0;
    padding-block: 28px 56px;
    padding-inline: 16px;
    background: var(--ground);
    color: var(--ink);
    font-family: "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif;
    line-height: 1.5;
  }}

  .wrap {{ max-width: 1180px; margin: 0 auto; }}

  .eyebrow {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.7rem;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--dim);
    margin: 0 0 8px;
  }}
  h1 {{
    font-size: clamp(1.45rem, 3.4vw, 2rem);
    font-weight: 600;
    letter-spacing: -0.015em;
    margin: 0 0 8px;
    text-wrap: balance;
  }}
  .lede {{ margin: 0 0 22px; color: var(--dim); max-width: 64ch; }}

  /* Choosing a film. A plain list of names, numbered because the tour is an
     order: the early ones are the keys everything else is reached through. */
  .films {{
    display: flex;
    gap: 7px;
    overflow-x: auto;
    padding-bottom: 8px;
    margin-bottom: 14px;
  }}
  .film-pick {{
    flex: 0 0 auto;
    font: inherit;
    font-size: 0.84rem;
    display: flex;
    align-items: baseline;
    gap: 7px;
    max-width: 82vw;
    background: var(--panel);
    color: var(--ink);
    border: 1px solid var(--edge);
    border-radius: 999px;
    padding: 6px 14px;
    cursor: pointer;
    white-space: normal;
    text-align: left;
  }}
  .film-pick .no {{
    flex: 0 0 auto;
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.72rem;
    color: var(--dim);
    font-variant-numeric: tabular-nums;
  }}
  .film-pick:hover {{ border-color: var(--accent); }}
  .film-pick[aria-current="true"] {{
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
  }}
  .film-pick[aria-current="true"] .no {{ color: rgba(255,255,255,0.72); }}

  .stage {{
    background: var(--panel);
    border: 1px solid var(--edge);
    border-radius: 12px;
    overflow: hidden;
  }}
  .caption {{ padding: 14px 16px 0; }}
  .caption h2 {{ font-size: 1.02rem; font-weight: 600; margin: 0 0 3px; }}
  .caption p {{ margin: 0; color: var(--dim); font-size: 0.9rem; }}

  /* The frame is 120 columns wide whatever the screen is. On a phone it is
     scaled down rather than clipped: a third of the editor's state is not a
     useful view of the editor's state. */
  .screen {{
    margin: 12px 16px 0;
    background: var(--screen-bg);
    border-radius: 8px;
    padding: 10px 12px;
    overflow: hidden;
  }}
  .screen-inner {{ transform-origin: top left; }}
  pre {{
    margin: 0;
    white-space: pre;
    display: inline-block;
    font-family: "IBM Plex Mono", "JetBrainsMono Nerd Font", ui-monospace, monospace;
    font-size: 13px;
    line-height: 1.3;
  }}

  .transport {{
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 16px;
    flex-wrap: wrap;
  }}
  button {{
    font: inherit;
    font-size: 0.84rem;
    color: var(--ink);
    background: var(--cap);
    border: 1px solid var(--edge);
    border-radius: 7px;
    padding: 6px 12px;
    cursor: pointer;
  }}
  button:hover {{ border-color: var(--accent); color: var(--accent); }}
  button:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
  .now {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.8rem;
    color: var(--dim);
    font-variant-numeric: tabular-nums;
    margin-left: auto;
  }}

  .strip {{
    display: flex;
    gap: 7px;
    overflow-x: auto;
    padding: 11px 16px;
    background: var(--rail);
    border-top: 1px solid var(--edge);
  }}
  .cel {{
    flex: 0 0 auto;
    display: flex;
    flex-direction: column;
    gap: 4px;
    align-items: flex-start;
    background: var(--panel);
    border: 1px solid var(--edge);
    border-radius: 8px;
    padding: 7px 10px;
    cursor: pointer;
    min-width: 88px;
    /* A key sequence is the point of the cel, so it is never cut. Long ones —
       an Ex command used to set a scene — wrap onto a second line instead of
       running past the edge, which on a phone hid the end of every one. */
    max-width: min(320px, 74vw);
  }}
  .cel:hover {{ border-color: var(--accent); }}
  .cel[aria-current="true"] {{
    border-color: var(--accent);
    box-shadow: inset 0 -2px 0 var(--accent);
  }}
  .cel .n {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.64rem;
    color: var(--dim);
    font-variant-numeric: tabular-nums;
  }}
  .cel .k {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.8rem;
    color: var(--accent);
    white-space: normal;
    overflow-wrap: anywhere;
    text-align: left;
  }}

  .foot {{
    margin-top: 22px;
    color: var(--dim);
    font-size: 0.86rem;
    max-width: 68ch;
  }}
  code {{
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.86em;
    background: var(--cap);
    border: 1px solid var(--edge);
    border-radius: 4px;
    padding: 1px 5px;
  }}
  @media (prefers-reduced-motion: reduce) {{
    * {{ transition: none !important; animation: none !important; }}
  }}
</style>

<div class="wrap">
  <p class="eyebrow">{eyebrow}</p>
  <h1>{title}</h1>
  <p class="lede">{subtitle}</p>

  <div class="films" id="films" role="tablist" aria-label="Films"></div>

  <div class="stage">
    <div class="caption">
      <h2 id="film-title"></h2>
      <p id="film-blurb"></p>
    </div>
    <div class="screen" id="screen-box">
      <div class="screen-inner" id="screen-inner"><pre id="screen"></pre></div>
    </div>
    <div class="transport">
      <button id="play">Play</button>
      <button id="prev" aria-label="Previous frame">&larr;</button>
      <button id="next" aria-label="Next frame">&rarr;</button>
      <button id="zoom">Actual size</button>
      <span class="now"><span id="count"></span></span>
    </div>
    <div class="strip" id="strip"></div>
  </div>

  <p class="foot">{foot}</p>
</div>

<script>
const FILMS = {films};

const filmsBar = document.getElementById("films");
const strip = document.getElementById("strip");
const screen = document.getElementById("screen");
const screenBox = document.getElementById("screen-box");
const screenInner = document.getElementById("screen-inner");
const filmTitle = document.getElementById("film-title");
const filmBlurb = document.getElementById("film-blurb");
const count = document.getElementById("count");
const play = document.getElementById("play");
const zoom = document.getElementById("zoom");

let film = 0;
let at = 0;
let timer = null;
let fit = true;

FILMS.forEach((entry, index) => {{
  const pick = document.createElement("button");
  pick.className = "film-pick";
  pick.type = "button";
  pick.setAttribute("role", "tab");
  pick.innerHTML = '<span class="no">' + String(index + 1).padStart(2, "0") + '</span><span class="t"></span>';
  pick.querySelector(".t").textContent = entry.title;
  pick.addEventListener("click", () => {{ stop(); load(index); }});
  filmsBar.appendChild(pick);
}});

const picks = Array.from(filmsBar.children);

function rescale() {{
  screenInner.style.transform = "none";
  const natural = screen.scrollWidth;
  const room = screenBox.clientWidth - 24;
  // Scale both ways. A 120-column pane is narrower than a desktop panel and
  // wider than a phone, and leaving it at natural size wastes a third of the
  // width on one and clips two thirds on the other. Capped so a very wide
  // window does not blow the text up.
  const scale = fit ? Math.min(room / natural, 1.5) : 1;
  screenInner.style.transform = "scale(" + scale + ")";
  screenBox.style.height = (screen.scrollHeight * scale + 20) + "px";
  screenBox.style.overflowX = scale === 1 ? "auto" : "hidden";
  zoom.textContent = fit ? "Actual size" : "Fit to width";
}}

function show(index) {{
  const frames = FILMS[film].frames;
  at = Math.max(0, Math.min(index, frames.length - 1));
  screen.innerHTML = frames[at].html;
  count.textContent = (at + 1) + " / " + frames.length;
  Array.from(strip.children).forEach((cel, i) =>
    cel.setAttribute("aria-current", i === at ? "true" : "false"));
  if (strip.children[at]) strip.children[at].scrollIntoView({{ block: "nearest", inline: "nearest" }});
  rescale();
}}

function load(index) {{
  film = index;
  const entry = FILMS[film];
  filmTitle.textContent = entry.title;
  filmBlurb.textContent = entry.blurb;
  picks.forEach((pick, i) => pick.setAttribute("aria-current", i === film ? "true" : "false"));
  picks[film].scrollIntoView({{ block: "nearest", inline: "nearest" }});

  strip.textContent = "";
  entry.frames.forEach((frame, i) => {{
    const cel = document.createElement("button");
    cel.className = "cel";
    cel.type = "button";
    cel.innerHTML = '<span class="n">' + String(i + 1).padStart(2, "0") + '</span><span class="k"></span>';
    cel.querySelector(".k").textContent = frame.key;
    cel.addEventListener("click", () => {{ stop(); show(i); }});
    strip.appendChild(cel);
  }});

  show(0);
}}

function stop() {{
  if (timer) {{ clearInterval(timer); timer = null; }}
  play.textContent = "Play";
}}

function start() {{
  if (at >= FILMS[film].frames.length - 1) show(0);
  play.textContent = "Pause";
  timer = setInterval(() => {{
    if (at >= FILMS[film].frames.length - 1) {{ stop(); return; }}
    show(at + 1);
  }}, 1500);
}}

play.addEventListener("click", () => (timer ? stop() : start()));
document.getElementById("prev").addEventListener("click", () => {{ stop(); show(at - 1); }});
document.getElementById("next").addEventListener("click", () => {{ stop(); show(at + 1); }});
zoom.addEventListener("click", () => {{ fit = !fit; rescale(); }});
window.addEventListener("resize", rescale);

document.addEventListener("keydown", (event) => {{
  if (event.key === "ArrowLeft") {{ stop(); show(at - 1); event.preventDefault(); }}
  if (event.key === "ArrowRight") {{ stop(); show(at + 1); event.preventDefault(); }}
  if (event.key === " ") {{ timer ? stop() : start(); event.preventDefault(); }}
}});

load(0);
</script>
"""


def _read_film_entry(folder: Path) -> dict | None:
    frames = _read_frames(folder)
    if frames is None:
        return None
    named = folder / "title.txt"
    title = named.read_text(encoding="utf-8").strip() if named.exists() else folder.name
    blurb = folder / "blurb.txt"
    return {
        "title": title,
        "blurb": blurb.read_text(encoding="utf-8").strip() if blurb.exists() else "",
        "frames": frames,
    }


def build_tour_page(
    *,
    dir: str | Path,
    out: str | Path,
    title: str = "Neovim Tour",
    eyebrow: str = "Recorded in a real terminal",
    subtitle: str = "",
    foot: str = "",
    order: str = "",
) -> int:
    """BASE holds one subdirectory per film, each as film.py left it."""
    base = Path(dir)
    folders = [p for p in sorted(base.iterdir()) if p.is_dir()]
    if order:
        wanted = [name.strip() for name in order.split(",") if name.strip()]
        by_name = {p.name: p for p in folders}
        folders = [by_name[name] for name in wanted if name in by_name]

    films = []
    for folder in folders:
        entry = _read_film_entry(folder)
        if entry:
            films.append(entry)

    if not films:
        print(f"No films found under {base}", file=sys.stderr)
        return -1

    page = TOUR_PAGE.format(
        title=html.escape(title),
        eyebrow=html.escape(eyebrow),
        subtitle=html.escape(subtitle),
        foot=foot,
        films=json.dumps(films),
    )

    out_path = Path(out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(page, encoding="utf-8")
    return sum(len(f["frames"]) for f in films)


# -- scenario keys, in keymap notation (was scenario-keys.py) -------------

SPECIAL = {
    "Space": "<leader>",
    "Enter": "<CR>",
    "Escape": "<Esc>",
    "Tab": "<Tab>",
    "BSpace": "<BS>",
}


def _readable(tokens: list[str]) -> str:
    """Turn one scenario's key batches into something readable -- a recipe
    to reproduce the capture, not prose."""
    out: list[str] = []
    for token in tokens:
        if token in SPECIAL:
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


def scenario_keys() -> dict[str, str]:
    """Read SCENARIOS from tour.py directly -- a real data structure, not a
    bash source file re-parsed as text."""
    from .tour import SCENARIOS

    return {s.name: _readable([t for t in s.keys if t]) for s in SCENARIOS}


# -- CLI -------------------------------------------------------------------


def _cli() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ansi-to-html")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--title", default="nvim capture")
    p.add_argument("--font-size", type=int, default=15)

    p = sub.add_parser("contact-sheet")
    p.add_argument("--out", required=True)
    p.add_argument("--dir", required=True)
    p.add_argument("--title", default="Neovim feature tour")
    p.add_argument("--font-url")
    p.add_argument("--subtitle", default="")
    p.add_argument("--artifact", action="store_true")
    p.add_argument("captures", nargs="*")

    p = sub.add_parser("film")
    p.add_argument("--dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--title", default=None)
    p.add_argument("--subtitle", default="")
    p.add_argument("--font-size", type=int, default=13)
    p.add_argument("--artifact", action="store_true")
    p.add_argument("--eyebrow", default="Neovim, one frame per keystroke")

    p = sub.add_parser("tour")
    p.add_argument("--dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--title", default="Neovim Tour")
    p.add_argument("--eyebrow", default="Recorded in a real terminal")
    p.add_argument("--subtitle", default="")
    p.add_argument("--foot", default="")
    p.add_argument("--order", default="")

    sub.add_parser("scenario-keys")

    args = parser.parse_args()

    if args.cmd == "ansi-to-html":
        n = ansi_to_html(args.input, args.output, title=args.title, font_size=args.font_size)
        print(f"wrote {args.output} ({n} lines)")
        return 0

    if args.cmd == "contact-sheet":
        n = build_contact_sheet(
            out=args.out, dir=args.dir, captures=args.captures, title=args.title,
            subtitle=args.subtitle, font_url=args.font_url, artifact=args.artifact,
        )
        print(f"wrote {args.out} with {n} capture(s)")
        return 0

    if args.cmd == "film":
        n = build_film_page(
            dir=args.dir, out=args.out, title=args.title, subtitle=args.subtitle,
            font_size=args.font_size, artifact=args.artifact, eyebrow=args.eyebrow,
        )
        if n < 0:
            return 1
        print(f"{n} frames -> {args.out}")
        return 0

    if args.cmd == "tour":
        n = build_tour_page(
            dir=args.dir, out=args.out, title=args.title, eyebrow=args.eyebrow,
            subtitle=args.subtitle, foot=args.foot, order=args.order,
        )
        if n < 0:
            return 1
        print(f"tour -> {args.out}, {n} frames")
        return 0

    if args.cmd == "scenario-keys":
        json.dump(scenario_keys(), sys.stdout, indent=2, sort_keys=True)
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
