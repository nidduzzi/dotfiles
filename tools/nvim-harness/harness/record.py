"""Record the editing/agent/stress tours as films, one film per feature.
Replaces record-tour.sh, record-agent-tour.sh, record-stress-tour.sh.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Callable, Sequence

from . import probes
from .film import record as film_record


def _make_wanted(requested: Sequence[str]) -> Callable[[str], bool]:
    if not requested:
        return lambda name: True
    return lambda name: any(pick in name for pick in requested)


def _write_blurb(out_dir: Path, name: str, blurb: str) -> None:
    (out_dir / name / "blurb.txt").write_text(blurb + "\n")


def _film(out: Path, name: str, title: str, blurb: str, keys: Sequence[str], *,
          config_dir: str, appname: str, workdir: str,
          key_wait: float = 1.6, slow_wait: float | None = None) -> None:
    film_record(list(keys), out=str(out / name), title=title,
                config_dir=config_dir, appname=appname, workdir=workdir,
                trust=True, boot_wait=90, key_wait=key_wait, slow_wait=slow_wait)
    _write_blurb(out, name, blurb)


# ---------------------------------------------------------------- editing --

def record_editing(*, out: str, project: str, config_dir: str, appname: str = "nvim-lazyvim") -> None:
    if not project or not Path(project).is_dir():
        raise SystemExit(f"A project to record against is required: -p DIR (got {project!r})")
    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Recording into {out_dir}")

    lua_project = os.environ.get(
        "LUA_PROJECT", str(Path.home() / "dotfiles" / ".worktrees" / "nvim-lazyvim")
    )

    def film(name: str, title: str, blurb: str, *keys: str, film_pause: float = 1.6) -> None:
        print(f"  {name}")
        _film(out_dir, name, title, blurb, keys, config_dir=config_dir,
              appname=appname, workdir=project, key_wait=film_pause)

    def film_in(project_dir: str, name: str, title: str, blurb: str, *keys: str,
                film_pause: float = 1.6) -> None:
        print(f"  {name}  (in {Path(project_dir).name})")
        _film(out_dir, name, title, blurb, keys, config_dir=config_dir,
              appname=appname, workdir=project_dir, key_wait=film_pause)

    film("01-grep", "One grep key, many scopes",
         "The filter lives inside the search rather than on a key of its own. "
         "a-s widens it without leaving the picker.",
         "Space", "ff", "tasks/api", "Enter", "Space", "sg", "get_queryset", "M-s")

    film("02-files", "Finding a file",
         "The other half of search. Type any part of the path; the ranking "
         "prefers what you open often.",
         "Space", "ff", "serializers")

    film("03-buffers", "Back to a buffer",
         "Leader leader, where it was before. LazyVim puts Find Files here; "
         "this keeps buffers.",
         "Space", "ff", "tasks/api", "Enter", "Space", "ff", "tasks/models", "Enter", "Space", "Space")

    film("04-filters", "Narrowing a search",
         "a-e limits to file extensions the project actually contains, a-G to a "
         "path, a-c ignores case. None of them are on a key you would guess, "
         "which is why a-/ lists them.",
         "Space", "sg", "queryset", "M-e")

    film("05-capabilities", "What can this editor do",
         "Ask in words rather than remembering a key. Tab moves between "
         "everything, this configuration's own features, every mapping, and "
         "every command.",
         "Space", "ff", "tasks/api", "Enter", "Space", "?", "tab", "Tab", "Tab")

    film("06-commands", "Finding a command you cannot name",
         "tabclose is not guessable and :help only answers once you have the "
         "word. Type what it does instead — and the key that runs it is "
         "listed beside it.",
         "Space", "ff", "tasks/api", "Enter", "Space", "?", "Tab", "Tab", "Tab", "close")

    film("07-tree", "The file tree",
         "A tree when a list is the wrong shape. i filters it in place.",
         "Space", "e")

    film("08-diff", "Diffing the working tree",
         "Side by side, and the same key closes it.",
         "Space", "ff", "tasks/api", "Enter", "Space", "gd")

    film("09-harpoon", "Pinning the files you keep returning to",
         "Four or five files carry most of a change. Pin them and they get "
         "their own short list.",
         "Space", "ff", "tasks/api", "Enter", "Space", "ha", "Space", "hh")

    film("10-yank", "Everything you yanked",
         "Not just the last thing. Enter loads the register; p pastes it "
         "where you meant.",
         "Space", "ff", "tasks/api", "Enter", "yy", "jj", "yy", "Space", "sy")

    # lua_ls indexes the workspace before it can answer hover, so this needs
    # a longer settle than the rest or it answers "unknown".
    film_in(lua_project, "11-lsp", "Asking the language server",
            "K for what this is. Recorded in Lua rather than Python on "
            "purpose: label-studio provides ruff, and ruff answers neither "
            "hover nor definition. lua_ls is the one server this "
            "configuration installs itself, so it is the one that always "
            "has an answer. The symbol is picked to have one: vim.fs.find, "
            "the earlier choice, is assembled at runtime by "
            "vim._defer_require, so lua_ls can see the name and not the "
            "type and honestly answers \"unknown\" — which reads as a "
            "broken popup rather than an answered question.",
            "Space", "ff", "util/settings", "Enter", "/", "fs_stat", "Enter", "K",
            film_pause=6)

    film("12-flash", "Jumping by label",
         "s labels every match on screen; type a label to land there. f and "
         "t are the same idea along one line. These six keys carry no "
         "description of their own, which is why the editor writes one for "
         "them.",
         "Space", "ff", "tasks/api", "Enter", "s", "se")

    film("13-health", "What this project provides",
         "Only lua_ls installs itself. Everything else is used if the "
         "project or PATH provides it, and named if it does not.",
         ":checkhealth dotfiles", "Enter")

    film_in(lua_project, "14-popup", "Getting inside a popup",
            "K opens the hover unfocused. K again moves the cursor inside "
            "it — watch the status line stop naming the file — so c-d "
            "scrolls the popup rather than the buffer. c-c leaves, putting "
            "the cursor back where it was. No mouse either way, and the "
            "same twice-to-enter works for the diagnostic under the "
            "cursor.",
            "Space", "ff", "util/settings", "Enter", "/", "fs_stat", "Enter", "K", "K", "C-d", "C-c",
            film_pause=5)

    film_in(lua_project, "15-dismiss", "One key closes anything",
            "Every overlay used to close differently: q here, Esc there, "
            "the opening key somewhere else. c-c now returns you to normal "
            "from all of them — picker, popup, plugin window, split. Lazy "
            "is the pointed one: c-c was its own key for aborting an "
            "install, so abort moved to c-x and c-c means here what it "
            "means everywhere. In a terminal c-c still interrupts the "
            "program, and a-q closes that. <leader>xx is not shown here on "
            "purpose: Trouble opens no window when the file has no "
            "diagnostics, so the frame would show a key that looks like it "
            "did nothing.",
            "Space", "ff", "util/settings", "Enter", "Space", "ff", "C-c", "Space", "l", "C-c",
            film_pause=4)

    print()
    print(f"Films in {out_dir}")
    for p in sorted(out_dir.iterdir()):
        print(p.name)


# ------------------------------------------------------------------ agent --

def record_agent(*, out: str, project: str, config_dir: str, appname: str = "nvim-lazyvim",
                  backend: str = "hermes", names: Sequence[str] = ()) -> None:
    if not project or not Path(project).is_dir():
        raise SystemExit(f"A project to record against is required: -p DIR (got {project!r})")
    if backend == "hermes" and not os.environ.get("CUSTOM_BASE_URL"):
        raise SystemExit(
            "CUSTOM_BASE_URL is not set, so there is no model to ask.\n"
            "Source the environment that points Hermes at one first, or -b claude."
        )
    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Recording into {out_dir}")
    print(f"Model: {os.environ.get('HERMES_INFERENCE_MODEL', 'default')} "
          f"via {os.environ.get('HERMES_INFERENCE_PROVIDER', 'default')}")

    # Switch the editor to the backend, the way anyone would: the key, the
    # name, Enter. Every film does this fresh, since it is a session setting.
    switch = ["Space", "au", backend, "Enter"]
    open_ = ["Space", "ff", "core/utils/params", "Enter"]
    at_function = ["/", "def int_from_request", "Enter", "8j"]

    wanted = _make_wanted(names)
    film_pause = float(os.environ.get("FILM_PAUSE", "2"))
    agent_pause = float(os.environ.get("AGENT_PAUSE", "600"))

    def film(name: str, title: str, blurb: str, *keys: str) -> None:
        if not wanted(name):
            return
        print(f"  {name}")
        _film(out_dir, name, title, blurb, keys, config_dir=config_dir,
              appname=appname, workdir=project, key_wait=film_pause,
              slow_wait=agent_pause)

    film("00-settings", "Which settings are in force, and from where",
         "Every setting has four tiers, in the order the shell and tmux "
         "config already use: built in, then this machine's local.lua, "
         "then the project's .nvim.lua through vim.g, then whatever you "
         "set for this session. The panel names the value and the tier it "
         "came from, so \"which agent is answering\" is a question with an "
         "answer rather than a guess.",
         *open_, "Space", "a?")

    film("01-review", "A review you have to type your way out of",
         "Findings arrive as diagnostics, so ]d walks them and you fix them "
         "by typing, and a picker lists them because diagnostics answer "
         "\"what is wrong here\" and not \"what did it find\". The list "
         "truncates a finding to its column; Enter jumps to the line and "
         "the whole thing appears under it, wrapped. Nothing is applied, "
         "and there is no key here that edits a buffer.",
         *open_, *at_function, *switch, "Space", "slow:ar", "Enter")

    film("02-scope", "Widening what gets reviewed",
         "The same shape as the grep filter: one key moves the scope out "
         "from this function to the file to only what you changed. It is "
         "a-s here rather than <leader>as, because the findings list owns "
         "the keyboard while it is open — <leader>as is the same thing "
         "from the buffer, once it is closed.",
         *open_, *at_function, *switch, "Space", "slow:ar", "slow:M-s")

    film("03-hint-one", "A hint that withholds the answer",
         "The first rung names the class of problem and nothing else. No "
         "function, no library, no steps — the part where you work it out "
         "still has to happen.",
         *open_, *at_function, *switch, "Space", "slow:ah")

    film("04-hint-two", "Pressing again for one rung more",
         "Approach, then what to look up, then the signature. The ladder "
         "resets when you move somewhere else, so it measures how stuck "
         "you are here.",
         *open_, *at_function, *switch, "Space", "slow:ah", "Space", "slow:ah")

    film("05-lookup", "Looking something up",
         "The rung that makes you faster rather than the one that makes "
         "you think. Remembering an argument order was never the skill.",
         *open_, *switch, "Space", "al", "python bisect insort", "slow:Enter")

    # Recorded on a real ruff error (a genuine version mismatch in this
    # checkout) rather than a clean function, so the panel demonstrates the
    # explain-an-error half of this key, not the explain-this-code half.
    film("06-explain", "What this error means",
         "With a diagnostic under the cursor it explains that instead, "
         "because that is almost always the question. <leader>cd puts the "
         "error on screen first, so what the agent was given is visible "
         "before what it answered. The diagnostic goes into the prompt "
         "with the surrounding lines — the agent runs with no tools and "
         "reads nothing itself, so everything it sees is assembled here.",
         "Space", "ff", "stats/models", "Enter", "19G", *switch, "Space", "cd", "Space", "slow:ax")

    film("07-switch", "Choosing which agent answers",
         "<leader>au lists the ones this machine can actually run — Codex "
         "is defined and absent from the list because it is not on PATH, "
         "since a CLI-driven agent has no API to fall back to. Claude "
         "Code, Hermes and Codex differ in how they go headless and how "
         "they are stopped from writing, and one that has not been shown "
         "to refuse a write is refused rather than warned about.",
         *open_, "Space", "au")

    film("08-cost", "What it has cost",
         "c-c closes the findings list first, because a picker owns the "
         "keyboard while it is open and <leader>a$ typed into its filter "
         "box is two characters rather than a key. Then: real money on a "
         "hosted model, nothing on a local one, and either way visible "
         "rather than discovered later on a bill.",
         *open_, *at_function, *switch, "Space", "slow:ar", "C-c", "Space", "a$")

    print()
    print(f"Films in {out_dir}")
    for p in sorted(out_dir.iterdir()):
        print(p.name)


# ----------------------------------------------------------------- stress --

def _tracked_files(project: str) -> int:
    try:
        result = subprocess.run(
            ["git", "-C", project, "ls-files"], capture_output=True, text=True
        )
        return len(result.stdout.splitlines())
    except OSError:
        return 0


def _probe_line(out_dir: Path, project: str, key: str) -> str:
    stress = out_dir / "probes" / f"{Path(project).name}.stress"
    if not stress.is_file():
        return ""
    for line in stress.read_text().splitlines():
        parts = line.split(None, 1)
        if parts and parts[0] == key:
            return parts[1].strip() if len(parts) > 1 else ""
    return ""


def _run_probes(out_dir: Path, project: str, config_root: str, appname: str) -> None:
    name = Path(project).name
    probes_dir = out_dir / "probes"
    probes_dir.mkdir(parents=True, exist_ok=True)
    print(f"  probes ({name})")
    log_path = probes_dir / f"{name}.log"
    proj_out = probes_dir / name
    try:
        with open(log_path, "w") as log:
            import contextlib
            import io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                probes.run(project=project, config_root=config_root, appname=appname,
                           out_dir=str(proj_out))
            log.write(buf.getvalue())
    except SystemExit:
        pass
    except Exception as exc:
        log_path.write_text(f"{exc}\n")
    for src_name, dst_suffix in (("stress.txt", ".stress"), ("perf.txt", ".perf")):
        src = proj_out / src_name
        if src.is_file():
            (probes_dir / f"{name}{dst_suffix}").write_text(src.read_text())


def record_stress(*, out: str, projects_dir: str, config_root: str,
                   appname: str = "nvim-lazyvim", names: Sequence[str] = ()) -> None:
    if not Path(projects_dir).is_dir():
        raise SystemExit(f"No such directory: {projects_dir}")
    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)

    wanted = _make_wanted(names)

    def film_in(project: str, name: str, title: str, blurb: str, *keys: str) -> None:
        if not wanted(name):
            return
        if not Path(project).is_dir():
            print(f"  {name}  SKIPPED, no {project}")
            return
        tracked = _tracked_files(project)
        print(f"  {name}  ({Path(project).name}, {tracked} files)")
        _film(out_dir, name, title, blurb, keys, config_dir=config_root,
              appname=appname, workdir=project, key_wait=3)
        blurb_path = out_dir / name / "blurb.txt"
        blurb_path.write_text(
            f"{blurb}\n\nRecorded against {Path(project).name}, {tracked} tracked files.\n"
        )

    python_project = str(Path(projects_dir) / "label-studio")
    c_project = str(Path(projects_dir) / "crun")
    docs_project = str(Path(projects_dir) / "migml")

    print(f"Recording into {out_dir}")

    for project in (python_project, c_project, docs_project):
        if Path(project).is_dir():
            _run_probes(out_dir, project, config_root, appname)

    film_in(python_project, "01-grep-large", "Grepping five thousand files",
            "The definition ranks above the tests that call it. Ordering is "
            "computed from treesitter, not from a list of filename patterns.",
            "Space", "sg", "def get_queryset")

    film_in(python_project, "02-files-large", "Finding a file among sixty thousand",
            "Sixty thousand files on disk, five and a half thousand tracked. "
            "The picker filters the tracked ones.",
            "Space", "ff", "core/utils/params", "Enter")

    film_in(python_project, "03-capabilities-large",
            "Everything this editor can do, in a large project",
            "Nine hundred and eighty two entries, filtered as you type. The "
            "list is the same everywhere; the buffer-local half changes "
            "with the file.",
            "keys:Space ?", "worktree", "Tab", "Tab")

    film_in(c_project, "04-grep-c", "The same key in a C project",
            "No Python, no ruff, and the ranking works the same way because "
            "it asks treesitter rather than the file extension.",
            "Space", "sg", "container_create")

    film_in(docs_project, "05-docs-filter", "A project that is mostly documentation",
            "Two hundred and ninety three markdown files against a hundred "
            "and twenty yaml. a-s cycles the filter so prose can be "
            "excluded, included, or searched on its own.",
            "Space", "sg", "workflow", "M-s")

    film_in(python_project, "06-health", "What the editor says about this project",
            "Which language servers this project provides, which it does "
            "not, and which keys were overwritten since startup.",
            ":checkhealth dotfiles", "Enter")

    print()
    print(f"Films in {out_dir}")
    for p in sorted(out_dir.iterdir()):
        if p.name != "probes":
            print(p.name)

    print()
    print("Probe reports:")
    probes_dir = out_dir / "probes"
    if probes_dir.is_dir():
        for report in sorted(probes_dir.glob("*.perf")):
            print(f"  {report.stem}")
            for line in report.read_text().splitlines():
                print(f"    {line}")


# --------------------------------------------------------------------- CLI --

def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="kind", required=True)

    editing = sub.add_parser("editing")
    editing.add_argument("-o", dest="out", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "nvim-tour"))
    editing.add_argument("-p", dest="project", required=True)
    editing.add_argument("-c", dest="config_dir",
                          default=os.environ.get("NVIM_TOUR_CONFIG", str(Path.home() / "dotfiles" / ".worktrees" / "cfg")))
    editing.add_argument("-n", dest="appname", default=os.environ.get("NVIM_TOUR_APPNAME", "nvim-lazyvim"))

    agent = sub.add_parser("agent")
    agent.add_argument("-o", dest="out", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "nvim-agent-tour"))
    agent.add_argument("-p", dest="project", required=True)
    agent.add_argument("-c", dest="config_dir",
                        default=os.environ.get("NVIM_TOUR_CONFIG", str(Path.home() / "dotfiles" / ".worktrees" / "cfg")))
    agent.add_argument("-n", dest="appname", default=os.environ.get("NVIM_TOUR_APPNAME", "nvim-lazyvim"))
    agent.add_argument("-b", dest="backend", default="hermes")
    agent.add_argument("names", nargs="*")

    stress = sub.add_parser("stress")
    stress.add_argument("-o", dest="out", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "nvim-stress-tour"))
    stress.add_argument("-r", dest="projects_dir",
                         default=os.environ.get("NVIM_STRESS_PROJECTS", str(Path.home() / "Documents" / "projects")))
    stress.add_argument("-c", dest="config_root",
                         default=os.environ.get("NVIM_TOUR_CONFIG", None) or
                         str((Path(__file__).resolve().parent.parent / ".." / ".worktrees" / "cfg").resolve()))
    stress.add_argument("-n", dest="appname", default=os.environ.get("NVIM_TOUR_APPNAME", "nvim-lazyvim"))
    stress.add_argument("names", nargs="*")

    args = parser.parse_args()

    if args.kind == "editing":
        record_editing(out=args.out, project=args.project, config_dir=args.config_dir, appname=args.appname)
    elif args.kind == "agent":
        record_agent(out=args.out, project=args.project, config_dir=args.config_dir,
                     appname=args.appname, backend=args.backend, names=args.names)
    elif args.kind == "stress":
        record_stress(out=args.out, projects_dir=args.projects_dir, config_root=args.config_root,
                       appname=args.appname, names=args.names)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
