# dotfiles

WARNING: This includes submodules of foreign repositories

## Install

```sh
git clone --recurse-submodules <this repo> ~/dotfiles
cd ~/dotfiles
stow bash-omb tmux-omt tmux-local neovim
tools/shell/install-local-bashrc.sh
```

`stow -D <package>` removes a package, `stow -R <package>` reinstalls one.

A fresh clone needs no editing. Everything that differs between machines is
read from files outside the shared config, so the shared files stay identical
on every host.

## Packages

| Package      | Provides                                                      |
| ------------ | ------------------------------------------------------------- |
| `bash-basic` | A plain shared bashrc for machines without oh-my-bash          |
| `bash-omb`   | oh-my-bash shared bashrc plus the shell config tiers           |
| `tmux-basic` | A minimal `.tmux.conf` with tpm                                |
| `tmux-omt`   | The gpakosz/.tmux submodule, kept pristine                     |
| `tmux-local` | Our tmux overrides and the tmux config tiers                   |
| `neovim`     | The Neovim config submodule                                    |
| `niri`       | niri `config.kdl` and the hand-written `dms/binds.kdl`         |
| `mise`       | mise `config.toml`: global node, python and uv, uv-managed venvs |

`bash-basic` and `bash-omb` both provide `~/.config/shell/bashrc`, so install one or the
other. The same applies to `tmux-basic` and `tmux-omt` plus `tmux-local`.

## niri

`stow niri` links `~/.config/niri`. `config.kdl` includes `dms/*.kdl`, which
DankMaterialShell writes itself (colours follow the wallpaper), so only
`dms/binds.kdl` is tracked and the rest is ignored. niri fails on a missing
include, so on a new machine run `dms run` once, or create empty files for
the `dms/` includes, before starting niri. Per-machine monitor settings belong
in `dms/outputs.kdl`, which DMS manages.

## Three tiers of configuration

Machine-specific settings used to be edited straight into the shared files,
which then followed you to every other machine. Config now loads in three
tiers, least specific first, so a later tier always wins:

| Tier       | Committed? | bash                                     | tmux                                     |
| ---------- | ---------- | ---------------------------------------- | ---------------------------------------- |
| **shared** | yes        | `~/.config/shell/shared/*.sh`            | `~/.config/tmux/shared/*.conf`           |
| **host**   | yes        | `~/.config/shell/hosts/$(hostname -s).sh`| `~/.config/tmux/hosts/$(hostname -s).conf` |
| **local**  | never      | `~/.config/shell/local/*.sh`             | `~/.config/tmux/local/*.conf`            |

Use the **host** tier for settings worth keeping when you rebuild that machine:
a data mount that only exists there, a cluster it talks to. Use the **local**
tier for anything temporary. The local directories are inside the repo so that
`stow` links them, but `.gitignore` covers their contents, so nothing you put
there can be committed by accident.

None of these files has to exist. A machine with no host file and an empty
local directory gets the shared tier and nothing else.

## `~/.bashrc` belongs to the machine

Installers append their setup lines to `~/.bashrc` without asking. When
`~/.bashrc` was a symlink into this repo, those lines landed in shared config
and followed you to every machine. That is how `k3s` completion and a Hugging
Face cache path ended up in the shared file.

So `~/.bashrc` is now a plain file that is never committed. The shared config
is `~/.config/shell/bashrc`, stowed from this repo, and
`tools/shell/install-local-bashrc.sh` adds a line to `~/.bashrc` that
loads it, after anything already there so the shared config wins over a
distribution's default `~/.bashrc`:

```sh
case $- in
  *i*) ;;
  *) return ;;
esac
source "${XDG_CONFIG_HOME:-$HOME/.config}/shell/bashrc"
```

Whatever an installer appends goes below that line and stays on this
machine. To share a setting, move it into a tier above. The script keeps the
contents of an existing plain `~/.bashrc` below the new line, and does
nothing on a second run. `~/.bashrc_local` is still loaded for machines that
have one.

### Moving a machine over

A machine set up before this has `~/.bashrc` linked to `bash-omb/.bashrc`
(or `bash-basic/.bashrc`) in the repo. That file stays as a short stub that loads the shared config, so
pulling never leaves the link dangling, and `stow` no longer links it
anywhere new (`.stow-local-ignore`). Move over whenever convenient:

```sh
cd ~/dotfiles && git pull
stow -R bash-omb            # or bash-basic
tools/shell/install-local-bashrc.sh
```

Anything an installer appended to the stub in the meantime moves into the new
`~/.bashrc`, and the stub goes back to its committed content. If the stub was
edited rather than appended to, the script stops and changes nothing.

## Why `tmux-local` exists separately

gpakosz's `.tmux.conf` reads your overrides from `~/.tmux.conf.local`. That
file used to live inside the `tmux-omt` submodule, so customising tmux meant
committing to a fork of someone else's repo and fighting merge conflicts on
every upstream update.

`tmux-local` now provides `~/.tmux.conf.local` instead. The submodule holds
nothing but upstream, apart from one line in its `.stow-local-ignore` that
stops it claiming that filename.

## Why tmux used to take every session down at once

The tmux server was ending up in the cgroup of whichever SSH login started it:

```
server cgroup: 0::/user.slice/user-1000.slice/session-18210.scope
pane   cgroup: 0::/user.slice/user-1000.slice/session-18210.scope
```

It belongs under `user@1000.service`. tmux tries to move itself and each pane
into scopes of their own there, and on this machine every one of those moves
fails:

```
tmux-spawn-….scope: Couldn't move process … Input/output error
tmux-spawn-….scope: Failed to add PIDs to scope's control group: Permission denied
```

So the server and every pane of every session stayed inside one login session
scope. When systemd stopped that scope, because the connection dropped or
logind reaped the session, everything in it was killed at once. No crash, no
core dump, nothing in `/var/crash`, which is why it never looked like what it
was, and why `tmux attach` afterwards reported no sessions.

`tmux.service` fixes it by letting the user manager own the server:

```sh
systemctl --user enable --now tmux.service
tmux attach                      # attach as usual afterwards
```

Verify it took:

```sh
cat /proc/$(tmux display -p '#{pid}')/cgroup
# want: /user.slice/user-1000.slice/user@1000.service/app.slice/tmux.service
# not:  /user.slice/user-1000.slice/session-NNNNN.scope
```

Lingering must stay on, or the user manager stops at logout:

```sh
loginctl enable-linger $USER
```

Started this way, the per-pane scopes also succeed, so the log spam stops too.

## Why restored panes came back in the wrong directory

resurrect saves `pane_current_path`, the cwd of the pane's foreground process.
Run `nvim ~/projects/thing/file.lua` from your home directory and nvim never
changes directory, so the pane's cwd genuinely is your home directory. The
pane title said `thing` only because nvim set it. resurrect saved the truth and
restored it; what was missing was the work.

The saved files showed the second half of this: the final field of every pane
line was empty, and `restore.sh` skips any pane whose full command is empty. No
program was being restored at all, because `@resurrect-processes` was never
set. It is now, in `~/.config/tmux/shared/20-resurrect.conf`, with a `~` prefix
so programs come back with their arguments and the files reopen whatever the
cwd was.

## Catching the next tmux death

`tmux -vv` writes its log into the current directory at server start, so it
cannot simply be aliased: every `tmux ls` would leave log files wherever you
were standing, and starting the server from a log directory would make new
sessions open there. These functions handle both halves, starting the server
from the log directory while the session keeps the directory you are in.

```sh
tmux-debug           # start a logged server and attach
tmux-debug-status    # where the logs are, and whether the server is logging
tmux-debug-last      # last 40 lines of the server log, after a death
tmux-debug-off       # back to a normal server
```

Logging can only be turned on when the server starts, so a server that is
already running has to be replaced:

```sh
tmux kill-server && tmux-debug
```

After a death, `tmux-debug-last` shows what the server was parsing when it
stopped. A busy server writes tens of megabytes an hour, because every escape
sequence is recorded, so turn it off once the fault is understood.

## Tools

| Script                                  | Purpose                                            |
| --------------------------------------- | -------------------------------------------------- |
| `tools/shell/install-local-bashrc.sh`   | Make `~/.bashrc` local and load the shared config  |
| `tools/tmux/crash-capture.sh`           | Run tmux with logging and core dumps enabled       |
| `tools/tmux/nvim-startup-repro.sh`      | Start Neovim in tmux repeatedly, watching for death |
| `tools/tmux/fake-terminal.py`           | Attach a pty that answers terminal queries          |
| `tools/tmux/sixel-crash-repro.sh`       | Try to crash a tmux server with sixel, safely      |
| `tools/nvim-harness/nvim-drive.sh`      | Drive Neovim in an isolated tmux and capture it    |
| `tools/nvim-harness/ansi-to-html.py`    | Turn a capture into a viewable picture             |

See `tools/nvim-harness/README.md` for how to verify a Neovim change visually.
