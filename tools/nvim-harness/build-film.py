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


ARTIFACT_PAGE = """<title>{title}</title>
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True, help="directory film.sh wrote")
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default=None)
    parser.add_argument("--subtitle", default="")
    parser.add_argument("--font-size", type=int, default=13)
    parser.add_argument(
        "--artifact",
        action="store_true",
        help="emit a page for the Artifact host, which supplies its own skeleton",
    )
    parser.add_argument("--eyebrow", default="Neovim, one frame per keystroke")
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

    template = ARTIFACT_PAGE if args.artifact else PAGE
    fields = dict(
        title=html.escape(title),
        subtitle=html.escape(args.subtitle or f"{len(frames)} frames, one per keystroke"),
        font_size=args.font_size,
        frames=json.dumps(frames),
    )
    if args.artifact:
        fields["eyebrow"] = html.escape(args.eyebrow)
        fields["bg"] = ansi.BASE_COLOURS[0] if hasattr(ansi, "BASE_COLOURS") else "#11121a"
    page = template.format(**fields)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    print(f"{len(frames)} frames -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
