#!/usr/bin/env python3
"""Compare two keymap dumps and report what the second one did to the first.

Three things worth knowing, and one of them is a bug most of the time:

  taken over  the key existed upstream and now does something else. Sometimes
              deliberate; sometimes it quietly removed a working feature, which
              is what happened to workspace diagnostics and Source Action here.
  added       a key that did not exist upstream. Free, unless it collides with
              something a plugin adds later.
  lost        a key that existed upstream and is now gone entirely.

Usage:
    keymap-collisions.py BASELINE.json CURRENT.json [--expected FILE]

`--expected` names a file of `mode<TAB>lhs` lines that are known and accepted,
so the report shows only what is new since anyone last looked.
"""

from __future__ import annotations

import argparse
import json
import sys


def load(path: str) -> dict[tuple[str, str], dict]:
    with open(path, encoding="utf-8") as handle:
        entries = json.load(handle)
    # Buffer-local wins over global, so it is what the key actually does.
    ranked = {}
    for entry in entries:
        key = (entry["mode"], entry["lhs"])
        if key not in ranked or entry["scope"] == "buffer":
            ranked[key] = entry
    return ranked


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("current")
    parser.add_argument("--expected")
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="only print the counts and anything unexpected",
    )
    args = parser.parse_args()

    baseline = load(args.baseline)
    current = load(args.current)

    expected = set()
    if args.expected:
        try:
            with open(args.expected, encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        mode, _, lhs = line.partition("\t")
                        expected.add((mode.strip(), lhs.strip()))
        except OSError:
            pass

    taken, added, lost = [], [], []

    for key, entry in sorted(current.items()):
        if key not in baseline:
            added.append(entry)
            continue

        before = baseline[key]
        # A description change is the signal: same key, different meaning.
        if (before["desc"] or before["rhs"]) != (entry["desc"] or entry["rhs"]):
            taken.append((before, entry))

    for key, entry in sorted(baseline.items()):
        if key not in current:
            lost.append(entry)

    unexpected = [
        (b, c) for b, c in taken if (c["mode"], c["lhs"]) not in expected
    ] + [(e, None) for e in lost if (e["mode"], e["lhs"]) not in expected]

    print(f"taken over: {len(taken)}   added: {len(added)}   lost: {len(lost)}")
    print(f"unexpected: {len(unexpected)}")

    if taken and not args.quiet:
        print("\n== taken over ==")
        for before, after in taken:
            flag = " " if (after["mode"], after["lhs"]) in expected else "!"
            print(f"{flag} {after['lhs']:<20} {after['mode']:<2}")
            print(f"    was: {before['desc'] or before['rhs']}")
            print(f"    now: {after['desc'] or after['rhs']}")

    if lost and not args.quiet:
        print("\n== lost ==")
        for entry in lost:
            flag = " " if (entry["mode"], entry["lhs"]) in expected else "!"
            print(f"{flag} {entry['lhs']:<20} {entry['mode']:<2} {entry['desc'] or entry['rhs']}")

    if added and not args.quiet:
        print(f"\n== added ({len(added)}) ==")
        for entry in added:
            print(f"  {entry['lhs']:<20} {entry['mode']:<2} {entry['desc'] or entry['rhs']}")

    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
