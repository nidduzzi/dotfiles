"""Run the stress/perf/parity probes against a real project and assert a
budget on the blocking calls. Replaces run-probes.sh.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from .driver import HARNESS_DIR, drive

INCLUDE_EXTS = (".py", ".ts", ".tsx", ".js", ".go", ".rs", ".lua", ".rb")


def _run_lua_probe(
    *, env_var: str, out_file: Path, probe_lua: str,
    config_root: str, appname: str, project: str, wait_secs: float,
) -> None:
    env_before = os.environ.get(env_var)
    os.environ[env_var] = str(out_file)
    try:
        drive(
            [f"ex:luafile {HARNESS_DIR / probe_lua}"],
            config_dir=config_root, appname=appname, workdir=project,
            trust=True, boot_wait=90, key_wait=wait_secs,
        )
    except Exception:
        pass
    finally:
        if env_before is None:
            os.environ.pop(env_var, None)
        else:
            os.environ[env_var] = env_before


def _report(title: str, path: Path) -> bool:
    """Print the report; return True if it ran (non-empty)."""
    print()
    print(f"== {title} ==")
    if path.is_file() and path.stat().st_size > 0:
        print(path.read_text(), end="")
        return True
    print("did not run")
    return False


def run(
    *,
    project: str,
    config_root: str | None = None,
    appname: str = "nvim-lazyvim",
    out_dir: str | None = None,
    budget_ms: float = 500,
    parity_symbol: str | None = None,
) -> int:
    if not Path(project).is_dir():
        raise SystemExit(f"No such project: {project}")

    config_root = config_root or os.environ.get(
        "NVIM_TOUR_CONFIG", str((HARNESS_DIR / ".." / ".." / ".worktrees" / "cfg").resolve())
    )
    out = Path(out_dir or (Path(os.environ.get("TMPDIR", "/tmp")) / "nvim-probes"))
    out.mkdir(parents=True, exist_ok=True)

    # Cleared: a report that did not run this time is otherwise a stale one.
    stress_file = out / "stress.txt"
    perf_file = out / "perf.txt"
    parity_file_out = out / "parity.txt"
    for f in (stress_file, perf_file, parity_file_out):
        f.unlink(missing_ok=True)

    status = 0
    print(f"project: {project}")

    _run_lua_probe(env_var="NVIM_STRESS_OUT", out_file=stress_file,
                    probe_lua="stress-probe.lua", config_root=config_root,
                    appname=appname, project=project, wait_secs=12)
    if not _report("what this project looks like", stress_file):
        status = 1
    else:
        m = re.search(r"^startup_errors\s+(\d+)", stress_file.read_text(), re.MULTILINE)
        startup_errors = int(m.group(1)) if m else 0
        if startup_errors > 0:
            print()
            print(f"{startup_errors} error(s) during startup.")
            status = 1

    _run_lua_probe(env_var="NVIM_PERF_OUT", out_file=perf_file,
                    probe_lua="stress-perf.lua", config_root=config_root,
                    appname=appname, project=project, wait_secs=12)
    if not _report("how long the blocking calls take", perf_file):
        status = 1
    else:
        over_budget = [
            line for line in perf_file.read_text().splitlines()
            if (m := re.search(r"(\d+\.\d+)ms", line)) and float(m.group(1)) > budget_ms
        ]
        if over_budget:
            print()
            print(f"over the {budget_ms}ms budget:")
            for line in over_budget:
                print(line)
            status = 1

    if parity_symbol:
        # A file containing the symbol is found and opened first, so there
        # is a real buffer for a language server to attach to.
        parity_file: str | None = None
        for root, _dirs, files in os.walk(project):
            for name in files:
                if Path(name).suffix in INCLUDE_EXTS:
                    path = Path(root) / name
                    try:
                        if parity_symbol in path.read_text(errors="ignore"):
                            parity_file = str(path.resolve())
                            break
                    except OSError:
                        continue
            if parity_file:
                break

        if not parity_file:
            print()
            print("== what each language server answers ==")
            print(f"no file under {project} contains '{parity_symbol}'")
            status = 1
        else:
            env_before_symbol = os.environ.get("NVIM_LSP_PARITY_SYMBOL")
            env_before_file = os.environ.get("NVIM_LSP_PARITY_FILE")
            os.environ["NVIM_LSP_PARITY_SYMBOL"] = parity_symbol
            os.environ["NVIM_LSP_PARITY_FILE"] = parity_file
            try:
                _run_lua_probe(env_var="NVIM_LSP_PARITY", out_file=parity_file_out,
                                probe_lua="lsp-parity.lua", config_root=config_root,
                                appname=appname, project=project, wait_secs=20)
            finally:
                for var, before in (("NVIM_LSP_PARITY_SYMBOL", env_before_symbol),
                                    ("NVIM_LSP_PARITY_FILE", env_before_file)):
                    if before is None:
                        os.environ.pop(var, None)
                    else:
                        os.environ[var] = before
            _report("what each language server answers", parity_file_out)

    print()
    print(f"reports in {out}")
    return status


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-p", dest="project", required=True)
    parser.add_argument("-c", dest="config_root")
    parser.add_argument("-n", dest="appname", default="nvim-lazyvim")
    parser.add_argument("-o", dest="out_dir")
    parser.add_argument("-b", dest="budget_ms", type=float, default=500)
    parser.add_argument("-s", dest="parity_symbol")
    args = parser.parse_args()

    return run(
        project=args.project, config_root=args.config_root, appname=args.appname,
        out_dir=args.out_dir, budget_ms=args.budget_ms, parity_symbol=args.parity_symbol,
    )


if __name__ == "__main__":
    raise SystemExit(_cli())
