# dotfiles

WARNING: This includes submodules of foreign repositories

## Install

```sh
git clone --recurse-submodules <this repo> ~/dotfiles
cd ~/dotfiles
stow bash-omb tmux-omt tmux-local neovim
```

`stow -D <package>` removes a package, `stow -R <package>` reinstalls one.

A fresh clone needs no editing. Everything that differs between machines is
read from files outside the shared config, so the shared files stay identical
on every host.

## Packages

| Package      | Provides                                                      |
| ------------ | ------------------------------------------------------------- |
| `bash-basic` | A plain `.bashrc` for machines without oh-my-bash              |
| `bash-omb`   | oh-my-bash `.bashrc` plus the shell config tiers               |
| `tmux-basic` | A minimal `.tmux.conf` with tpm                                |
| `tmux-omt`   | The gpakosz/.tmux submodule, kept pristine                     |
| `tmux-local` | Our tmux overrides and the tmux config tiers                   |
| `neovim`     | The Neovim config submodule                                    |

`bash-basic` and `bash-omb` both claim `~/.bashrc`, so install one or the
other. The same applies to `tmux-basic` and `tmux-omt` plus `tmux-local`.

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

## Keeping the shared `.bashrc` clean

`~/.bashrc` is a symlink into this repo, so installers that append their setup
lines to it are writing into config that every machine shares. That is how
`k3s` completion and a Hugging Face cache path ended up in the shared file.

The shared `.bashrc` ends with an append guard marker. Anything an installer
adds lands below it, where it is easy to spot and easy to move:

```sh
tools/shell/harvest-appended.sh --show   # what got appended
tools/shell/harvest-appended.sh          # move it to the local tier
tools/shell/harvest-appended.sh --host   # move it to this machine's tier
```

Run it after installing anything that edits your shell profile, then check
`git status` before committing.

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

## Tools

| Script                                  | Purpose                                            |
| --------------------------------------- | -------------------------------------------------- |
| `tools/shell/harvest-appended.sh`       | Move installer-appended lines out of shared config |
| `tools/tmux/crash-capture.sh`           | Run tmux with logging and core dumps enabled       |
| `tools/tmux/sixel-crash-repro.sh`       | Try to crash a tmux server with sixel, safely      |
| `tools/nvim-harness/nvim-drive.sh`      | Drive Neovim in an isolated tmux and capture it    |
| `tools/nvim-harness/ansi-to-html.py`    | Turn a capture into a viewable picture             |

See `tools/nvim-harness/README.md` for how to verify a Neovim change visually.
