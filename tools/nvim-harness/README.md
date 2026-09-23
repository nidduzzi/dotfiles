# Neovim harness

Drive a real Neovim, then look at what it actually drew.

Neovim changes are hard to check by reading the config. This harness starts
Neovim inside a tmux server of its own, sends keystrokes, and captures the
pane. Because the server uses a private socket name, a crash or a stray key
cannot reach the sessions you are working in.

Everything here is Python, invoked through one entry point,
`harness.py`, or its per-module CLIs (`python3 -m harness.gates syntax`, for
standalone use during development). Setup: `python3 -m pip install pynvim`
(RPC to the driven Neovim goes over a persistent `pynvim` connection, not a
shelled-out `nvim --server --remote-expr` per call).

## Capture text

```sh
python3 tools/nvim-harness/harness.py trial /path/to/repo
```

or, for scripted use, `harness.driver.NvimDriver` directly:

```py
from harness.driver import drive
print(drive(["Space", "/", "searchterm"], workdir="/path/to/repo"))
```

`NvimDriver`'s options mirror the old `nvim-drive.sh` flags:

- `config_dir` config directory to run against, as `XDG_CONFIG_HOME`
- `appname` `NVIM_APPNAME`, which also isolates plugin and state directories
- `workdir` directory Neovim opens in
- `boot_wait` how long to wait for startup, before the first keys
- `keep` keep the server alive afterwards so you can attach and poke at it

## Capture a picture

Plain text loses colour, highlight groups and window borders, which is usually
the part worth checking. Drive with `capture_ansi=True` and render with
`harness.reporting.ansi_to_html`:

```py
from harness.driver import NvimDriver
from harness.reporting import ansi_to_html

with NvimDriver(workdir="/path/to/repo", capture_ansi=True) as d:
    d.send_batch("Space"); d.send_batch("/"); d.send_batch("term")
    Path("/tmp/shot.html").write_text(ansi_to_html(d.capture()))
```

The renderer needs a Nerd Font installed for the file-type glyphs to draw as
icons rather than boxes.

## Trial configs

`trials/` holds Neovim configurations kept separate from the daily one, so a
distro or plugin can be tried without touching what you use for work. Each
trial gets its own plugin and state directories through `NVIM_APPNAME`.

```sh
# run a trial by hand
XDG_CONFIG_HOME=$PWD/tools/nvim-harness/trials NVIM_APPNAME=lazyvim-snacks nvim

# install its plugins without opening a window
XDG_CONFIG_HOME=$PWD/tools/nvim-harness/trials NVIM_APPNAME=lazyvim-snacks \
  nvim --headless '+Lazy! sync' +qa
```

| Trial            | What it is                                        |
| ---------------- | ------------------------------------------------- |
| `lazyvim-snacks` | Stock LazyVim, whose picker is `snacks.picker`    |

`lazyvim-snacks` is also the baseline the `keymaps` gate diffs against, so the
keys this configuration takes over can be told apart from the ones it inherits.
That is why it is kept once the picker question is settled.

`fixture/` is a small repository with source files, a `docs/` tree and an
`openspec/` tree, so picker and grep-filter behaviour can be compared against
the same content every time. It holds a git repository of its own, so it cannot
be committed as files; `harness.fixtures.build_fixture` generates it, with two
commits and three files left untracked on purpose.

```sh
python3 tools/nvim-harness/harness.py fixture --force
```

`debug-fixtures/` holds one small program per language for the debugger, built
by `harness.fixtures.build_debug_fixtures`. Each has a function taking two
arguments and a local, so a breakpoint has something to show. A language
whose toolchain is missing is skipped and named.

```sh
python3 tools/nvim-harness/harness.py debug-fixtures
```

## Gates

These assert something and exit non-zero when it fails. Everything above this
line captures; everything below it decides.

| Gate | What it fails on | Needs |
| --- | --- | --- |
| `harness.py syntax` | a Lua file that does not compile, or a path with no Lua in it | nothing |
| `duplicate-keys.py LUA_DIR` | the same key bound twice in this config | nothing |
| `harness.py keymaps` | a key taken from stock LazyVim, a key bound twice, a dead key, a key that describes nothing | the baseline trial |
| `harness.py screens` | a screen that no longer matches its committed copy | tmux, the fixture |
| `harness.py rung-flags-match` | the agent canary proving flags the editor does not send | nothing |
| `harness.py key-names` | a key batch tmux would send as a key rather than as text | tmux |
| `harness.py picker-keys` | a key the tour presses inside a picker that nothing is bound to, or a snacks key taken without saying so | the config |
| `harness.py capability-keys` | a key the capability list offers that nothing is bound to | the config, the fixture |
| `harness.py startup-plugins` | a plugin that loads before you ask for it | the config, the fixture |
| `harness.py dismiss` | an overlay one press of the dismiss key does not close, or a file it does | the config, the fixture |
| `harness.py startup-paths` | a way into an untrusted project that is not asked about, or a trusted one that is | the config, git |
| `harness.py probes -p PROJECT` | a probe that did not run, a blocking call over budget, or errors at startup | a project |
| `harness.py debuggers` | a language whose debugger never reached the breakpoint it was given | the config, the debug fixtures, tmux, a browser |
| `harness.py debuggers --headless` | the same, asked of nvim-dap directly: the check for machines with no tmux | the config, the debug fixtures |
| `harness.py check-agent` | an agent flow that opened its window and never answered | the config, a backend, real requests |
| `harness.py agent-canary AGENT RUNG` | an agent writing a file it should not, or a tool registry that is not what the rung promises | that agent's CLI, network |
| `harness.py tour -c CONFIG` | a scenario that could not be captured, or one whose frame does not contain what the feature draws | tmux, the fixture |

TSX is the one language in `harness.py debuggers` (either mode) that does not
gate: a real browser under contended CI hardware occasionally drops the DAP
session after a correct handshake, which is a property of the hardware, not a
bug this config can fix, and it was failing a job roughly one run in three. It
still runs and still prints what happened -- just under `flaky`, not
`failures`, so it cannot fail the build on its own.

`.github/workflows/harness.yml` runs almost everything above on every push,
in three parallel jobs rather than in the order the table lists them: `gates`
(ubuntu) runs every gate down through `harness.py debuggers` and, with `-l`,
`harness.py screens`; `debuggers-macos` and `debuggers-windows` repeat the
debugger check and the screens on their own platform (`--tmux` needs tmux,
which Windows does not have, so that job passes `--headless` instead,
filtered to the four languages that do not need a language server neither job
installs). `harness.py check-agent` and `harness.py agent-canary` need a
subscription CLI, so `canary.yml` runs those on dispatch rather than
pretending a runner can. `harness.py tour` is the nightly `schedule` trigger,
not any push -- the whole tour is dozens of editors started one after
another, and GitHub only runs a scheduled workflow from the repository's
default branch, so it stays inert here until this stack merges.

### Screens

A screen test is a `.keys` file and a `.expected` file beside it, in the
configuration's `tests/screen/`. The keys are batches, one per line, in the
same syntax `NvimDriver.send_batch` reads.

```sh
python3 tools/nvim-harness/harness.py screens                # every screen
python3 tools/nvim-harness/harness.py screens settings        # one
python3 tools/nvim-harness/harness.py screens -u settings      # accept what it drew
python3 tools/nvim-harness/harness.py screens -l               # include the ones needing a language server
```

Directives are `# name: value` lines at the top of a `.keys` file: `dir`,
`size`, `needs`, `attempts`, `pause`.

A screen is compared after normalisation, and what is normalised away is in
`harness/normalise.py`: the clock, the branch, paths, durations, plugin
counts, language-server progress, and spacing on the statusline. Each entry is
there because it changed between two machines while the editor behaved
identically.

A comparison retries before failing, because a language server answers when it
answers. The attempt number is printed when it is not the first, so a screen
that is only eventually right still says so.

### The feature tour

Each scenario in `harness/tour.py`'s `SCENARIOS` is a real dataclass, not a
string-encoded line: name, description, seconds to wait for the editor,
expected pattern, and the keys to send.

The expected pattern is an extended regular expression the captured frame has
to contain. Match on what the feature puts on the screen -- a picker title, a
message, the text a filter left behind. A pattern that would still match if
the key had been ignored is not a check: eight scenarios pressed keys that did
nothing and every one of them captured a frame.

## Recording

`harness.py record editing|agent|stress` captures a frame per keystroke and
`harness.reporting.build_tour_page` gathers them into one page. These assert
nothing; they are for reading.

## Trusting a project

`-t`/`trust=True` grants this project both kinds of trust: it answers
Neovim's prompt for a `.nvim.lua`, which runs Lua the project wrote, and it
records the project in the editor's own trust store, which is what lets the
project's programs run --- and, since git was gated, what lets gitsigns
attach and the diff, worktree and git picker keys work at all.

It does that only inside this harness, which is where the fixture is.
Anywhere else needs `-F`/`force_trust=True`, and wanting it is worth a second
thought.

## Everything here

| File | What it is |
| --- | --- |
| `harness.py` | single CLI entry point, dispatching to the modules below |
| `harness/driver.py` | drive one editor, capture the pane; `NvimDriver`, the core engine |
| `harness/film.py` | `NvimDriver` plus per-batch frame capture |
| `harness/fixtures.py` | generate the fixture repo and the per-language debug fixtures |
| `harness/gates.py` | syntax, keymaps, dismiss, startup-paths, startup-plugins, picker-keys, capability-keys, key-names |
| `harness/keymaps.py` | the `keymaps` gate's comparison logic, over `duplicate-keys.py`/`keymap-collisions.py` |
| `harness/debuggers.py` | every installed adapter stops where it is told to, tmux-driven or headless |
| `harness/screens.py` | screens match their committed copies |
| `harness/normalise.py` | what a screen comparison ignores |
| `harness/tour.py` | the feature tour: scenarios as data, each checked against what it drew |
| `harness/probes.py` | timings within budget, no startup errors |
| `harness/record.py` | the editing, agent and stress tours, one film per feature |
| `harness/agent.py` | the local agent check, the write-refusal canary, and the rung-flags-match comparison |
| `harness/trial.py` | open the configuration by hand, isolated from your everyday one |
| `harness/reporting.py` | ANSI-to-HTML rendering and the film/contact-sheet/tour page builders |
| `duplicate-keys.py` | one key bound twice, by reading the source |
| `keymap-collisions.py` | this config against the baseline trial |
| `dismiss-combinations.lua` | the overlays that gate opens, one at a time |
| `startup-plugins.lua` | which plugins are loaded, read from the running editor |
| `capability-keys.lua` | what that list claims, read from the running editor |
| `picker-keys.lua` | the picker's resolved key table, for that gate |
| `debug-headless.lua` | what the headless debugger gate runs inside the editor |
| `serve-fixture.js` | serves the browser fixture, in node rather than python |
| `keymap-audit.lua` | describe every mapping, and which describe nothing |
| `keymap-dump.lua` | every mapping as JSON, for the collision check |
| `lsp-parity.lua` | what each language server actually answers |
| `stress-probe.lua` | what a project looks like to the editor |
| `stress-perf.lua` | how long the blocking calls take |
| `expected-collisions.txt` | keys taken from LazyVim on purpose |
| `expected-dead-keys.txt` | keys left undescribed by someone else |
| `expected-picker-overrides.txt` | picker keys taken from snacks on purpose |
| `expected-startup-plugins.txt` | plugins that load at startup on purpose |
