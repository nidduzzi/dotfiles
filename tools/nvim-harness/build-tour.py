#!/usr/bin/env python3
"""Gather several recorded films into one tour.

film.sh records one feature into one directory. This collects a directory of
those and lays them out as a tour: pick a film, step through its frames, see
the key that produced each.

Captured at a desktop's width and read anywhere. A 120-column pane is about
900 pixels of monospace, which no phone has, so the frame scales to fit the
screen rather than forcing a horizontal scroll — the whole point is seeing the
editor's state, and a view showing a third of it shows nothing. The scale is a
transform, so the text stays text.

Usage:
    build-tour.py --dir BASE --out PAGE.html [--title TITLE]

BASE holds one subdirectory per film, each as film.sh left it.
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


def read_film(ansi, folder: Path) -> dict | None:
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
        style = ansi.Style()
        body = "\n".join(
            ansi.render_line(raw, style) for raw in path.read_text(encoding="utf-8").splitlines()
        )
        frames.append({"html": body, "key": key or "—"})

    if not frames:
        return None

    named = folder / "title.txt"
    title = named.read_text(encoding="utf-8").strip() if named.exists() else folder.name

    blurb = folder / "blurb.txt"
    return {
        "title": title,
        "blurb": blurb.read_text(encoding="utf-8").strip() if blurb.exists() else "",
        "frames": frames,
    }


PAGE = """<title>{title}</title>
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default="Neovim Tour")
    parser.add_argument("--eyebrow", default="Recorded in a real terminal")
    parser.add_argument("--subtitle", default="")
    parser.add_argument("--foot", default="")
    parser.add_argument("--order", default="", help="comma-separated folder names, in tour order")
    args = parser.parse_args()

    ansi = load_renderer()
    base = Path(args.dir)

    folders = [p for p in sorted(base.iterdir()) if p.is_dir()]
    if args.order:
        wanted = [name.strip() for name in args.order.split(",") if name.strip()]
        by_name = {p.name: p for p in folders}
        folders = [by_name[name] for name in wanted if name in by_name]

    films = []
    for folder in folders:
        film = read_film(ansi, folder)
        if film:
            films.append(film)

    if not films:
        print(f"No films found under {base}", file=sys.stderr)
        return 1

    page = PAGE.format(
        title=html.escape(args.title),
        eyebrow=html.escape(args.eyebrow),
        subtitle=html.escape(args.subtitle),
        foot=args.foot,
        films=json.dumps(films),
    )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")

    total = sum(len(f["frames"]) for f in films)
    print(f"{len(films)} films, {total} frames -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
