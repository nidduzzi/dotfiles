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
| `lazyvim-fzf`    | LazyVim with the fzf-lua picker extra instead     |

`fixture/` is a small generated repository with source files, a `docs/` tree
and an `openspec/` tree, so picker and grep-filter behaviour can be compared
against the same content every time. It is not tracked; recreate it by running
the snippet in this repository's history or by pointing the harness at any real
project instead.
