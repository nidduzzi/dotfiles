#!/usr/bin/env python3
"""Attach to tmux through a pseudo-terminal that answers like a real terminal.

The reported crash only happens with a client attached over SSH, while Neovim
is starting. Neovim's startup is the only time it interrogates the terminal,
and tmux relays those queries to whatever is attached, then parses the replies
that come back. With no client attached, tmux answers from terminfo and the
reply path never exists, so a detached reproduction tests nothing.

This provides the missing half: a pty that plays the part of the terminal and
answers the queries, so tmux has replies to parse. Which replies it gives can
be changed from the command line, to find the one that matters.

Usage:
    fake-terminal.py --socket NAME [options] [-- command ...]

Options:
    --socket NAME     tmux socket to attach to (required).
    --term TERM       TERM to claim. Default: xterm-256color.
    --profile NAME    Which terminal to imitate: wt, xterm, minimal.
    --no-sixel        Answer DA1 without the sixel attribute.
    --seconds N       How long to stay attached. Default: 12.
    --log FILE        Write every query seen and reply sent to FILE.

Exit status is 0 if the tmux server was still alive at the end, 1 if it died.
"""

from __future__ import annotations

import argparse
import errno
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

ESC = b"\x1b"

# Device Attributes replies. The numbers are feature codes; 4 means sixel
# graphics, which is what Windows Terminal started reporting in 1.22 and what
# makes tmux enable its own sixel handling for the client.
DA1_WITH_SIXEL = b"\x1b[?61;4;6;7;14;21;22;23;24;28;32;42c"
DA1_NO_SIXEL = b"\x1b[?61;6;7;14;21;22;23;24;28;32;42c"

PROFILES = {
    "wt": {
        "da2": b"\x1b[>0;10;1c",
        "xtversion": b"\x1bP>|WindowsTerminal(1.22.12111.0)\x1b\\",
    },
    "xterm": {
        "da2": b"\x1b[>41;377;0c",
        "xtversion": b"\x1bP>|XTerm(377)\x1b\\",
    },
    "minimal": {
        "da2": b"\x1b[>0;0;0c",
        "xtversion": b"",
    },
}


def build_responses(profile: str, sixel: bool) -> list[tuple[re.Pattern[bytes], bytes]]:
    """Map query patterns to the bytes a terminal would send back."""
    info = PROFILES[profile]

    return [
        # Primary Device Attributes.
        (re.compile(rb"\x1b\[c|\x1b\[0c"), DA1_WITH_SIXEL if sixel else DA1_NO_SIXEL),
        # Secondary Device Attributes.
        (re.compile(rb"\x1b\[>(?:0)?c"), info["da2"]),
        # Tertiary Device Attributes.
        (re.compile(rb"\x1b\[=c"), b"\x1bP!|00000000\x1b\\"),
        # XTVERSION.
        (re.compile(rb"\x1b\[>(?:0)?q"), info["xtversion"]),
        # Device Status Report, cursor position.
        (re.compile(rb"\x1b\[6n"), b"\x1b[1;1R"),
        (re.compile(rb"\x1b\[5n"), b"\x1b[0n"),
        # OSC 10/11, foreground and background colour.
        (re.compile(rb"\x1b\]10;\?(?:\x07|\x1b\\)"), b"\x1b]10;rgb:cccc/cccc/cccc\x1b\\"),
        (re.compile(rb"\x1b\]11;\?(?:\x07|\x1b\\)"), b"\x1b]11;rgb:0c0c/0c0c/0c0c\x1b\\"),
        # XTSMGRAPHICS: sixel geometry. Answering means graphics are available.
        (
            re.compile(rb"\x1b\[\?(\d+);(\d+)S"),
            b"\x1b[?2;0;1000;1000S" if sixel else b"\x1b[?2;3;0;0S",
        ),
        # Kitty keyboard protocol query.
        (re.compile(rb"\x1b\[\?u"), b"\x1b[?0u"),
        # XTGETTCAP. Reply that the capability is unknown, which is what a
        # terminal without the entry does.
        (re.compile(rb"\x1bP\+q([0-9A-Fa-f;]*)(?:\x1b\\|\x07)"), b"\x1bP0+r\x1b\\"),
        # DECRQM mode queries: report "reset".
        (re.compile(rb"\x1b\[\?(\d+)\$p"), b""),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--term", default="xterm-256color")
    parser.add_argument("--profile", default="wt", choices=sorted(PROFILES))
    parser.add_argument("--no-sixel", action="store_true")
    parser.add_argument("--seconds", type=float, default=12.0)
    parser.add_argument("--log")
    parser.add_argument("command", nargs="*")
    args = parser.parse_args()

    responses = build_responses(args.profile, not args.no_sixel)
    log = open(args.log, "wb") if args.log else None

    def note(text: str) -> None:
        if log:
            log.write(text.encode() + b"\n")
            log.flush()

    server_pid = subprocess.run(
        ["tmux", "-L", args.socket, "display", "-p", "#{pid}"],
        capture_output=True,
        text=True,
    ).stdout.strip()

    if not server_pid:
        print("No tmux server on that socket", file=sys.stderr)
        return 2

    note(f"server pid {server_pid}, profile {args.profile}, sixel {not args.no_sixel}")

    pid, master = pty.fork()
    if pid == 0:
        os.environ["TERM"] = args.term
        os.environ["COLORTERM"] = "truecolor"
        # A clean environment, so no inherited TMUX variable refuses the attach.
        os.environ.pop("TMUX", None)
        cmd = ["tmux", "-L", args.socket, "attach"]
        os.execvp(cmd[0], cmd)
        os._exit(1)

    # The window size tmux believes the terminal has.
    try:
        import fcntl
        import struct
        import termios

        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
    except Exception:
        pass

    deadline = time.time() + args.seconds
    pending = b""
    started = False

    while time.time() < deadline:
        ready, _, _ = select.select([master], [], [], 0.3)

        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno in (errno.EIO, errno.EBADF):
                    break
                raise

            if not chunk:
                break

            pending += chunk

            # Answer every query present in what tmux just sent.
            for pattern, reply in responses:
                for match in pattern.finditer(pending):
                    if reply:
                        os.write(master, reply)
                        note(f"query {match.group(0)!r} -> reply {reply!r}")
                    else:
                        note(f"query {match.group(0)!r} -> no reply")

            # Keep only a tail, in case a sequence straddles two reads.
            pending = pending[-4096:]

        if not started and args.command:
            # Give tmux a moment to finish attaching before running the command.
            time.sleep(1.0)
            subprocess.run(
                ["tmux", "-L", args.socket, "new-window", "-d"] + args.command,
                check=False,
            )
            started = True

        if not _alive(server_pid):
            note("server died")
            print(f"SERVER DIED after {args.seconds - (deadline - time.time()):.1f}s")
            _reap(pid)
            if log:
                log.close()
            return 1

    _reap(pid)
    if log:
        log.close()

    if not _alive(server_pid):
        print("SERVER DIED")
        return 1

    print("server survived")
    return 0


def _alive(pid: str) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, ValueError):
        return False
    except PermissionError:
        return True


def _reap(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())
