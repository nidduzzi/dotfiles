#!/usr/bin/env python3
"""Single entry point for the harness. Dispatches to each module's own CLI,
which stays independently invocable (`python3 -m harness.gates syntax`, etc.)
for standalone testing.

Usage:
    harness.py <command> [args...]
"""
from __future__ import annotations

import importlib
import sys

# name -> (module, subcommand to prepend, or None if the module's own parser
# takes no leading subcommand token)
COMMANDS = {
    "syntax": ("harness.gates", "syntax"),
    "startup-plugins": ("harness.gates", "startup-plugins"),
    "capability-keys": ("harness.gates", "capability-keys"),
    "picker-keys": ("harness.gates", "picker-keys"),
    "startup-paths": ("harness.gates", "startup-paths"),
    "dismiss": ("harness.gates", "dismiss"),
    "keymaps": ("harness.gates", "keymaps"),
    "key-names": ("harness.gates", "key-names"),
    "debuggers": ("harness.debuggers", None),
    "screens": ("harness.screens", None),
    "tour": ("harness.tour", None),
    "probes": ("harness.probes", None),
    "record": ("harness.record", None),
    "check-agent": ("harness.agent", "check-agent"),
    "agent-canary": ("harness.agent", "canary"),
    "rung-flags-match": ("harness.agent", "rung-flags-match"),
    "trial": ("harness.trial", None),
    "fixture": ("harness.fixtures", "fixture"),
    "debug-fixtures": ("harness.fixtures", "debug"),
}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        names = ", ".join(sorted(COMMANDS))
        print(f"usage: harness.py <command> [args...]\ncommands: {names}", file=sys.stderr)
        return 2

    module_name, prefix = COMMANDS[argv[0]]
    rest = argv[1:] if prefix is None else [prefix, *argv[1:]]
    module = importlib.import_module(module_name)

    if module_name == "harness.trial":
        return module._cli(rest)

    sys.argv = [module_name, *rest]
    return module._cli()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
