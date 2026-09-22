"""Drive Neovim through its features and capture what each one draws.

Replaces feature-tour.sh. SCENARIOS is a real data structure (not a
string-encoded bash array) so other gates -- check_picker_keys in
gates.py -- can read the keys each scenario presses without re-parsing
this file's source as text.
"""
from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from .driver import HARNESS_DIR, drive as _drive


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    wait: float
    expect: str  # an ERE the capture must contain
    keys: tuple[str, ...] = field(default_factory=tuple)


# expect is matched on what the feature itself draws (a title, a message),
# never on chrome that would still be there had the key done nothing.
SCENARIOS: tuple[Scenario, ...] = (
    # -- discovery -----------------------------------------------------
    Scenario("startup", "Dashboard on an empty start", 14, "Neovim loaded"),
    Scenario("whichkey-leader", "Key hints: leader menu", 14, r"f ➜",
             (" ff", "lib.lua", "Enter", "Escape", "Space")),
    Scenario("whichkey-search", "Key hints: the search group", 14, r"w ➜",
             (" ff", "lib.lua", "Enter", "Escape", " s")),
    Scenario("whichkey-goto", "Key hints: the goto prefix", 14, "Move to",
             (" ff", "lib.lua", "Enter", "Escape", "g")),
    # -- finding files and text -----------------------------------------
    Scenario("find-files", "Search files", 14, "Files", (" ff",)),
    Scenario("grep-code", "Search file contents, documentation excluded", 14,
             r"Grep \(code\)", (" sg", "validateToken")),
    Scenario("grep-all", "Search file contents, everything", 14, r"Grep \(all\)",
             (" sg", "validateToken", "M-S", "all", "wait:2:Enter")),
    Scenario("grep-docs", "Search documentation only", 14, r"Grep \(docs\)",
             (" sg", "validateToken", "M-S", "docs", "wait:2:Enter")),
    Scenario("grep-word", "Search the word under the cursor", 14, r"Grep \(code\)",
             (" ff", "auth.js", "Enter", ":3", "Enter", "w", " sw")),
    Scenario("grep-buffer", "Search lines in the current buffer", 14, "Lines",
             (" ff", "auth.js", "Enter", "wait:3: sb")),
    Scenario("grep-open", "Search across open buffers", 14, "Grep Buffers",
             (" ff", "auth.js", "Enter", " ff", "lib.lua", "Enter", " sB")),
    Scenario("grep-tree", "Results grouped by file in Trouble", 14, "Snacks",
             (" sg", "validateToken", "wait:10:C-t")),
    Scenario("fuzzy-files", "Fuzzy matching in the file picker", 14, "auth.js",
             (" ff", "athjs")),
    Scenario("fuzzy-toggle", "Grep, then C-g to fuzzy filter the results", 14,
             "README", (" sg", "validateToken", "C-g", "README")),
    Scenario("fuzzy-path", "Fuzzy filtering the results by path", 14, "src/",
             (" sg", "validateToken", "C-g", "src/")),
    Scenario("regex-default",
             "Regex is the default: token.*expiry matches, as ripgrep would",
             14, "expiresAt", (" sg", "token.*expiry")),
    Scenario("regex-toggle",
             "a-r switches to fixed-string matching, shown by R in the title",
             14, "0/0", (" sg", "M-r", "token.*expiry")),
    Scenario("filter-glob", "Restrict the search to a path glob with a-G", 14,
             r"Grep \(src/\*\*\)",
             (" sg", "validateToken", "M-G", "src/**", "wait:2:Enter")),
    Scenario("filter-glob-not", "Exclude a path glob, by prefixing it with !",
             14, r"Grep \(not src/\*\*\)",
             (" sg", "validateToken", "M-G", "!src/**", "wait:2:Enter")),
    Scenario("filter-ext", "Restrict the search to extensions with a-e", 14,
             r"Grep \(ext:js\)",
             (" sg", "validateToken", "M-e", "js", "wait:2:Enter")),
    Scenario("filter-choose", "Choosing a filter preset from a list with a-S",
             14, "Search filter", (" sg", "validateToken", "M-S")),
    Scenario("resume", "Resume the last search", 14, r"Grep \(code\)",
             (" sg", "validateToken", "wait:2:Escape", " sR")),
    Scenario("buffers", "Buffer list", 14, "Buffers",
             (" ff", "lib.lua", "Enter", " ff", "app.py", "Enter", ",")),
    Scenario("recent", "Recent files", 14, "Recent", (" fr",)),
    Scenario("help-tags", "Help tags", 14, "Help", (" sh",)),
    Scenario("keymaps", "Keymaps", 14, "Keymaps", (" sk",)),
    Scenario("marks", "Marks", 14, "Marks", (" sm",)),
    Scenario("explorer", "File tree explorer", 14, "Explorer", ("wait:3: e",)),
    Scenario("explorer-search",
             "Searching inside the tree: i focuses the filter, the tree stays a tree",
             14, "lib.lua", (" e", "i", "lua")),
    Scenario("explorer-search-deep",
             "A filter matching inside nested directories, shown in place", 14,
             "openspec", ("wait:3: e", "i", "wait:3:spec")),
    Scenario("explorer-grep", "Grep scoped to the directory under the cursor",
             14, "validateToken", (" e", "j", "j", " /", "validateToken")),
    # -- language servers -------------------------------------------------
    Scenario("lsp-hover", "Hover documentation", 14, "add: function",
             (" ff", "lib.lua", "Enter", ":8", "Enter", "ww", "K")),
    Scenario("lsp-refs", "References", 18, "Lsp References",
             (" ff", "lib.lua", "Enter", ":8", "Enter", "ww", "gr")),
    Scenario("lsp-def", "Definition", 18, "function M.add",
             (" ff", "lib.lua", "Enter", ":13", "Enter", "wwww", "gd")),
    Scenario("lsp-symbols", "Document symbols", 16, "Lsp Symbols",
             (" ff", "lib.lua", "Enter", " ss")),
    Scenario("lsp-workspace-symbols", "Workspace symbols", 16,
             "Lsp Workspace Symbols",
             (" ff", "lib.lua", "Enter", "wait:4: sS")),
    Scenario("lsp-rename", "Rename", 16, "New Name",
             (" ff", "lib.lua", "Enter", ":8", "Enter", "ww", " cr")),
    Scenario("lsp-codeaction", "Code actions", 18, "Code actions",
             (" ff", "broken.py", "Enter", ":9", "Enter", "ww", " ca")),
    Scenario("lsp-diagnostics", "Diagnostics for the buffer", 16,
             "imported but unused",
             (" ff", "broken.py", "Enter", "wait:4: xx")),
    Scenario("lsp-diagnostics-search", "Diagnostics picker", 16, "Diagnostics",
             (" ff", "broken.py", "Enter", " sd")),
    Scenario("lsp-line-diagnostic", "Diagnostic for the line", 16,
             "Undefined name",
             (" ff", "broken.py", "Enter", ":5", "Enter", " cd")),
    Scenario("lsp-inlay", "Inlay hints and signature help", 14, "a: number",
             (" ff", "lib.lua", "wait:6:Enter", "wait:2:j", "wait:2:k")),
    Scenario("completion", "Completion with documentation", 16,
             "Add two numbers together",
             (" ff", "lib.lua", "Enter", "GO", "M.ad")),
    Scenario("format", "Formatting a badly formatted file", 14,
             r"M.messy\(a, b\)", (" ff", "messy.lua", "Enter", " cf")),
    # -- git -----------------------------------------------------------
    Scenario("git-signs", "Git signs in a modified file", 14, "▎",
             (" ff", "login.js", "Enter")),
    Scenario("git-hunk", "Git hunk preview", 14, r"validateToken\(user\.token\);",
             (" ff", "login.js", "Enter", ":2", "Enter", "wait:3: ghp")),
    Scenario("git-blame", "Git blame for the line", 14, "Git Log Line",
             (" ff", "login.js", "Enter", ":1", "Enter", " gb")),
    Scenario("git-status", "Changed files", 14, "Git Status", (" gs",)),
    Scenario("git-log", "Commit log", 14, "Git Log", (" gl",)),
    # -- editing ---------------------------------------------------------
    Scenario("todo", "TODO, FIXME and HACK comments", 14, "Todo Comments",
             (" st",)),
    Scenario("yank-history", "Yank ring history", 14, "Yank History",
             (" ff", "lib.lua", "Enter", "yy", " sy")),
    Scenario("treesitter", "Syntax highlighting", 14, "function validateToken",
             (" ff", "auth.js", "Enter")),
    Scenario("folds", "Folded code", 14, "lines", (" ff", "auth.js", "Enter", "zM")),
    Scenario("terminal", "Terminal", 14, "terminal works",
             (" ft", "echo terminal works", "Enter")),
    Scenario("debug-ui", "Debugger breakpoint and menu", 14, "➜",
             (" ff", "app.py", "Enter", ":5", "Enter", " db", " d")),
    # -- the editor itself -------------------------------------------------
    Scenario("lazy", "Plugin manager", 14, "lazy.nvim", (" l",)),
    Scenario("mason", "Tool installer", 14, "Language Filter", ("wait:4: cm",)),
    Scenario("colorscheme", "Colourscheme picker", 14, "Colorschemes", (" uC",)),
    Scenario("health", "Which language servers this project provides", 14,
             "language servers", (":checkhealth dotfiles", "Enter")),
    Scenario("notifications", "Notification history", 14, "Notifications",
             (" sg", "validateToken", "M-c", "Escape", "wait:2: n")),
)


def scenario_keys() -> list[str]:
    """Every key token any scenario presses, `wait:N:` prefixes stripped."""
    keys: list[str] = []
    for scenario in SCENARIOS:
        for key in scenario.keys:
            keys.append(re.sub(r"^wait:[0-9]*:", "", key))
    return keys


def run(
    *,
    config_dir: str,
    appname: str | None = None,
    workdir: str | None = None,
    out_dir: str | None = None,
    filter_regex: str | None = None,
    attempts: int = 2,
) -> int:
    workdir = workdir or str(HARNESS_DIR / "fixture")
    out = Path(out_dir or (Path(os.environ.get("TMPDIR", "/tmp")) / "nvim-feature-tour"))
    out.mkdir(parents=True, exist_ok=True)

    if appname:
        state_home = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")))
        swap_dir = state_home / appname / "swap"
        if swap_dir.is_dir():
            for f in swap_dir.iterdir():
                f.unlink(missing_ok=True)

    print(f"config:   {config_dir} ({appname})")
    print(f"fixture:  {workdir}")
    print(f"output:   {out}")
    print()

    pattern = re.compile(filter_regex) if filter_regex else None
    captured: list[tuple[str, str]] = []
    failures: list[str] = []

    for scenario in SCENARIOS:
        if pattern and not pattern.search(scenario.name):
            continue

        print(f"{scenario.name:<16} {scenario.description} ... ", end="")
        sys.stdout.flush()

        ansi = out / f"{scenario.name}.ansi"
        drawn = out / f"{scenario.name}.drawn"
        drove = False
        attempt = 0
        for attempt in range(1, attempts + 1):
            try:
                capture = _drive(
                    scenario.keys,
                    config_dir=config_dir, appname=appname, workdir=workdir,
                    trust=True, no_shada=True, capture_ansi=True,
                    boot_wait=scenario.wait, key_wait=2,
                )
            except TimeoutError:
                drove = False
                continue

            ansi.write_text(capture + "\n")
            drove = True
            plain = re.sub(r"\x1b\[[0-9;]*m", "", capture)
            drawn.write_text(plain + "\n")
            if re.search(scenario.expect, plain):
                break

        if drove:
            plain = drawn.read_text()
            if re.search(scenario.expect, plain):
                drawn.unlink(missing_ok=True)
                captured.append((scenario.name, scenario.description))
                print(f"captured, on attempt {attempt}" if attempt > 1 else "captured")
            else:
                print(f"CAPTURED BUT EMPTY after {attempts} attempt(s): "
                      f"nothing matching /{scenario.expect}/, frame in {drawn}")
                failures.append(f"{scenario.name}: no /{scenario.expect}/")
        else:
            print("FAILED")
            failures.append(f"{scenario.name}: the driver gave up")

    print()
    print("Building the contact sheet")
    from .reporting import build_contact_sheet

    build_contact_sheet(
        out=out / "index.html",
        dir=out,
        captures=[f"{name}|{desc}" for name, desc in captured],
        title="Neovim feature tour",
    )

    print()
    print(f"Open {out / 'index.html'}")

    if failures:
        print()
        print(f"{len(failures)} of {len(captured) + len(failures)} scenarios failed:")
        for f in failures:
            print(f"  {f}")
        return 1
    return 0


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", dest="config_dir", required=True)
    parser.add_argument("-n", dest="appname")
    parser.add_argument("-d", dest="workdir")
    parser.add_argument("-o", dest="out_dir")
    parser.add_argument("-f", dest="filter_regex")
    parser.add_argument("-a", dest="attempts", type=int, default=2)
    args = parser.parse_args()

    return run(
        config_dir=args.config_dir, appname=args.appname, workdir=args.workdir,
        out_dir=args.out_dir, filter_regex=args.filter_regex, attempts=args.attempts,
    )


if __name__ == "__main__":
    raise SystemExit(_cli())
