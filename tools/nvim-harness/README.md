# Neovim harness

Drive a real Neovim, then look at what it actually drew.

Neovim changes are hard to check by reading the config. This harness starts
Neovim inside a tmux server of its own, sends keystrokes, and captures the
pane. Because the server uses a private socket name, a crash or a stray key
cannot reach the sessions you are working in.

## Capture text

```sh
tools/nvim-harness/nvim-drive.sh -d /path/to/repo 'Space' '/' 'searchterm'
```

Each argument after the options is a batch of keys in `tmux send-keys` syntax,
sent in order with a pause between batches. Useful options:

- `-c DIR` config directory to run against, as `XDG_CONFIG_HOME`
- `-n NAME` `NVIM_APPNAME`, which also isolates plugin and state directories
- `-d DIR` directory Neovim opens in
- `-w SECS` how long to wait for startup, before the first keys
- `-k` keep the server alive afterwards so you can attach and poke at it

## Capture a picture

Plain text loses colour, highlight groups and window borders, which is usually
the part worth checking. To get a real picture, capture with escape sequences
and render them:

```sh
tools/nvim-harness/nvim-drive.sh -e -o /tmp/shot.ansi -d /path/to/repo 'Space' '/' 'term'
python3 tools/nvim-harness/ansi-to-html.py /tmp/shot.ansi /tmp/shot.html
```

Open `/tmp/shot.html` in a browser, or serve the directory and screenshot it
headlessly:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory /tmp
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

`lazyvim-snacks` is also the baseline `check-keymaps.sh` diffs against, so the
keys this configuration takes over can be told apart from the ones it inherits.
That is why it is kept once the picker question is settled.

`fixture/` is a small repository with source files, a `docs/` tree and an
`openspec/` tree, so picker and grep-filter behaviour can be compared against
the same content every time. It holds a git repository of its own, so it cannot
be committed as files; `make-fixture.sh` generates it, with two commits and
three files left untracked on purpose.

```sh
tools/nvim-harness/make-fixture.sh --force
```

`debug-fixtures/` holds one small program per language for the debugger, built
by `make-debug-fixtures.sh`. Each has a function taking two arguments and a
local, so a breakpoint has something to show. A language whose toolchain is
missing is skipped and named.

```sh
tools/nvim-harness/make-debug-fixtures.sh
```

## Gates

These assert something and exit non-zero when it fails. Everything above this
line captures; everything below it decides.

| Gate | What it fails on | Needs |
| --- | --- | --- |
| `check-syntax.sh` | a Lua file that does not compile, or a path with no Lua in it | nothing |
| `duplicate-keys.py LUA_DIR` | the same key bound twice in this config | nothing |
| `check-keymaps.sh` | a key taken from stock LazyVim, a key bound twice, a dead key, a key that describes nothing | the baseline trial |
| `screen-test.sh` | a screen that no longer matches its committed copy | tmux, the fixture |
| `rung-flags-match.py` | the agent canary proving flags the editor does not send | nothing |
| `check-key-names.sh` | a key batch tmux would send as a key rather than as text | tmux |
| `check-picker-keys.sh` | a key the tour presses inside a picker that nothing is bound to, or a snacks key taken without saying so | the config |
| `check-capability-keys.sh` | a key the capability list offers that nothing is bound to | the config, the fixture |
| `check-startup-plugins.sh` | a plugin that loads before you ask for it | the config, the fixture |
| `check-dismiss.sh` | an overlay one press of the dismiss key does not close, or a file it does | the config, the fixture |
| `run-probes.sh -p PROJECT` | a probe that did not run, a blocking call over budget, or errors at startup | a project |
| `agent-canary.sh AGENT RUNG` | an agent writing a file it should not, or a tool registry that is not what the rung promises | that agent's CLI, network |
| `feature-tour.sh -c CONFIG` | a scenario that could not be captured, or one whose frame does not contain what the feature draws | tmux, the fixture |

`.github/workflows/harness.yml` runs the first ten on every push.
`agent-canary.sh` needs a subscription CLI, so `canary.yml` runs it on dispatch
rather than pretending a runner can.

### Screens

A screen test is a `.keys` file and a `.expected` file beside it, in the
configuration's `tests/screen/`. The keys are batches, one per line, in the
same syntax as `nvim-drive.sh`.

```sh
tools/nvim-harness/screen-test.sh                # every screen
tools/nvim-harness/screen-test.sh settings       # one
tools/nvim-harness/screen-test.sh -u settings    # accept what it drew
tools/nvim-harness/screen-test.sh -l             # include the ones needing a language server
```

Directives are `# name: value` lines at the top of a `.keys` file: `dir`,
`size`, `needs`, `attempts`, `pause`.

A screen is compared after normalisation, and what is normalised away is in
`screen-normalise.sed`: the clock, the branch, paths, durations, plugin
counts, language-server progress, and spacing on the statusline. Each entry is
there because it changed between two machines while the editor behaved
identically.

A comparison retries before failing, because a language server answers when it
answers. The attempt number is printed when it is not the first, so a screen
that is only eventually right still says so.

### The feature tour

Each scenario in `feature-tour.sh` is a line:

```
name | description | seconds to wait for the editor | expected pattern | keys...
```

The expected pattern is an extended regular expression the captured frame has
to contain. Match on what the feature puts on the screen -- a picker title, a
message, the text a filter left behind. A pattern that would still match if
the key had been ignored is not a check: eight scenarios pressed keys that did
nothing and every one of them captured a frame.

## Recording

`record-tour.sh`, `record-agent-tour.sh` and `record-stress-tour.sh` capture a
frame per keystroke and `build-tour.py` gathers them into one page. These
assert nothing; they are for reading.

## Trusting a project

`-t` grants this project both kinds of trust: it answers Neovim's prompt for a
`.nvim.lua`, which runs Lua the project wrote, and it records the project in
the editor's own trust store, which is what lets the project's programs run
--- and, since git was gated, what lets gitsigns attach and the diff, worktree
and git picker keys work at all.

It does that only inside this harness, which is where the fixture is. Anywhere
else needs `-F`, and wanting `-F` is worth a second thought.

## Everything here

| File | What it is |
| --- | --- |
| `try.sh [DIR]` | open the configuration by hand, isolated from your everyday one |
| `nvim-drive.sh` | drive one editor, capture the pane at the end |
| `film.sh` | drive one editor, capture a frame per key batch |
| `make-fixture.sh` | generate the repository the gates run against |
| `make-debug-fixtures.sh` | generate one small program per language for the debugger |
| `check-syntax.sh` | gate: every Lua file compiles |
| `check-keymaps.sh` | gate: collisions, duplicates, dead keys |
| `duplicate-keys.py` | gate: one key bound twice, by reading the source |
| `keymap-collisions.py` | gate: this config against the baseline trial |
| `screen-test.sh` | gate: screens match their committed copies |
| `rung-flags-match.py` | gate: the canary proves the flags the editor sends |
| `check-key-names.sh` | gate: no key batch is secretly a tmux key name |
| `check-picker-keys.sh` | gate: the keys that exist only inside a picker |
| `check-capability-keys.sh` | gate: the keys the capability list offers |
| `check-startup-plugins.sh` | gate: what loads at startup, against a baseline |
| `check-dismiss.sh` | gate: one press closes what is open, and not the file |
| `dismiss-combinations.lua` | the overlays that gate opens, one at a time |
| `startup-plugins.lua` | which plugins are loaded, read from the running editor |
| `capability-keys.lua` | what that list claims, read from the running editor |
| `picker-keys.lua` | the picker's resolved key table, for that gate |
| `run-probes.sh` | gate: timings within budget, no startup errors |
| `agent-canary.sh` | gate: an agent cannot write what its rung forbids |
| `feature-tour.sh` | gate: sixty scenarios, each checked against what it drew |
| `record-tour.sh` | the editing tour, one film per feature |
| `record-agent-tour.sh` | the agent tour, driven against a local model |
| `record-stress-tour.sh` | the same keys against real repositories |
| `build-tour.py` | films into one page |
| `build-film.py` | one film into one page |
| `build-contact-sheet.py` | captures into one page |
| `ansi-to-html.py` | a captured pane into HTML, used by the three builders |
| `scenario-keys.py` | the tour's key sequences as data |
| `keymap-audit.lua` | describe every mapping, and which describe nothing |
| `keymap-dump.lua` | every mapping as JSON, for the collision check |
| `lsp-parity.lua` | what each language server actually answers |
| `stress-probe.lua` | what a project looks like to the editor |
| `stress-perf.lua` | how long the blocking calls take |
| `screen-normalise.sed` | what a screen comparison ignores |
| `expected-collisions.txt` | keys taken from LazyVim on purpose |
| `expected-dead-keys.txt` | keys left undescribed by someone else |
| `expected-picker-overrides.txt` | picker keys taken from snacks on purpose |
| `expected-startup-plugins.txt` | plugins that load at startup on purpose |
