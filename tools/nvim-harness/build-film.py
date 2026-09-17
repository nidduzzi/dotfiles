#!/usr/bin/env python3
"""Turn a sequence of captured frames into a page you can step through.

film.sh records one frame per keystroke. This renders them with the same ANSI
reader the contact sheet uses, and lays them out as a film: play it, scrub it,
or step key by key with the arrow keys, with the key that produced each frame
shown beside it.

The point is the path, not the destination. A screenshot shows that a feature
exists; a film shows which key reached it and what changed on the way, which is
what someone learning the editor is missing.

Every frame is inlined, so the page is one file that works offline and can be
published as-is.

Usage:
    build-film.py --dir FRAME_DIR --out PAGE.html [--title TITLE]
"""

from __future__ import annotations

import argparse
import html
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_renderer():
    """Borrow the ANSI reader from the tool that already gets this right."""
    spec = importlib.util.spec_from_file_location("ansi_to_html", HERE / "ansi-to-html.py")
    if not spec or not spec.loader:
        raise SystemExit("Could not load ansi-to-html.py, which does the rendering")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PAGE = """<!doctype html>
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True, help="directory film.sh wrote")
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default=None)
    parser.add_argument("--subtitle", default="")
    parser.add_argument("--font-size", type=int, default=13)
    args = parser.parse_args()

    ansi = load_renderer()
    source = Path(args.dir)
    listing = source / "frames.tsv"
    if not listing.exists():
        print(f"No frames.tsv in {source}. Run film.sh first.", file=sys.stderr)
        return 1

    frames = []
    for line in listing.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        name, _, key = line.partition("\t")
        path = source / name
        if not path.exists():
            continue

        style = ansi.Style()
        body = "\n".join(
            ansi.render_line(raw, style) for raw in path.read_text(encoding="utf-8").splitlines()
        )
        frames.append({"html": body, "key": key or "—"})

    if not frames:
        print("No frames were rendered.", file=sys.stderr)
        return 1

    title = args.title
    if not title:
        named = source / "title.txt"
        title = named.read_text(encoding="utf-8").strip() if named.exists() else "Neovim"

    page = PAGE.format(
        title=html.escape(title),
        subtitle=html.escape(args.subtitle or f"{len(frames)} frames, one per keystroke"),
        font_size=args.font_size,
        frames=json.dumps(frames),
    )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    print(f"{len(frames)} frames -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
