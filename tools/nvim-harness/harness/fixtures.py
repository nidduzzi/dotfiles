"""Build the two fixture trees the gates run against. Replaces
make-fixture.sh and make-debug-fixtures.sh.

File content here is not documentation, it is test data: an LSP diagnostic,
a debugger breakpoint or a golden screen frame can depend on an exact line
number, so nothing in a heredoc-equivalent string below gets "cleaned up".
"""
from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

HARNESS_DIR = Path(__file__).resolve().parent.parent


def _run(cmd: list[str], cwd: Path | str | None = None, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=check, **kw)


def _git_identity(repo: Path) -> None:
    _run(["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"])
    _run(["git", "-C", str(repo), "config", "user.name", "Fixture"])


# -- make-fixture.sh --------------------------------------------------------

README_MD = """# Fixture repo

Sample repo for picker comparisons. Mentions validateToken.
"""

ARCHITECTURE_MD = """# Architecture

Auth uses validateToken at the edge.
"""

SPEC_MD = """# auth spec

## Requirement: validateToken
The system SHALL reject expired tokens.
"""

PROPOSAL_MD = """# Add auth

This change adds token validation.
The validateToken helper checks expiry.
"""

AUTH_JS_V1 = """function validateToken(token) {
  return token.expiresAt > Date.now();
}
"""

LOGIN_JS_V1 = """export function login(user) {
  return validateToken(user.token);
}
"""

AUTH_JS_V2 = """// TODO: rotate signing keys on a schedule
// FIXME: expiry check is off by one at the boundary
function validateToken(token) {
  // token expiry check
  return token.expiresAt > Date.now();
}

function issueToken(user) {
  return { sub: user.id, expiresAt: Date.now() + 3600_000 };
}

module.exports = { validateToken, issueToken };
"""

APP_PY = '''"""Sample module for the feature tour."""


def greet(name: str) -> str:
    # TODO: support localisation
    return f"hello {name}"


def main() -> None:
    print(greet("world"))
'''

LIB_LUA = """-- NOTE: used by the harness to show LSP features
local M = {}

--- Add two numbers together.
---@param a number
---@param b number
---@return number
function M.add(a, b)
  return a + b
end

function M.double(n)
  return M.add(n, n)
end

return M
"""

NVIM_LUA = """-- Per-project settings for this repository, read by Neovim's exrc.
vim.g.search_filters = {
  docs = { "openspec/**" },
  presets = {
    { name = "specs", desc = "openspec specs only", globs = { "openspec/specs/**" } },
  },
}
"""

LOGIN_JS_V2 = """export function login(user) {
  return validateToken(user.token) && user.active;
}

// HACK: temporary shim, remove before release
module.exports.legacy = true;
"""

BUGGY_LUA = """-- NOTE: used by the harness to show the Claude review.
--
-- Every function here has a defect that a reviewer should be able to point at,
-- so a review that finds nothing is a broken review rather than clean code.
local M = {}

--- Take the first n items. Holes when n is larger than the list.
function M.take(items, n)
  local out = {}
  for i = 1, n do
    out[i] = items[i]
  end
  return out
end

--- Average. Divides by zero on an empty list.
function M.mean(numbers)
  local total = 0
  for _, n in ipairs(numbers) do
    total = total + n
  end
  return total / #numbers
end

--- Read a file. Leaks the handle when the read throws.
function M.read(path)
  local fd = io.open(path, "r")
  local text = fd:read("*a")
  fd:close()
  return text
end

return M
"""

BROKEN_PY = '''"""Deliberately broken, so the diagnostics view has something to show."""


def compute(values):
    total = undefined_helper(values)
    return total / 0


def unused_import_demo():
    import os

    return 1
'''

MESSY_LUA = """local M={}
function M.messy(  a,b )
      return a+b
end
return M
"""


def build_fixture(dir: str | Path | None = None, force: bool = False) -> Path:
    target = Path(dir) if dir else HARNESS_DIR / "fixture"

    if target.exists() and not force:
        print(f"{target} already exists. Pass --force to rebuild it.", file=sys.stderr)
        raise SystemExit(2)

    if shutil.which("git") is None:
        print("git is required", file=sys.stderr)
        raise SystemExit(1)

    shutil.rmtree(target, ignore_errors=True)
    (target / "src").mkdir(parents=True)
    (target / "docs").mkdir(parents=True)
    (target / "openspec" / "specs" / "auth").mkdir(parents=True)
    (target / "openspec" / "changes" / "add-auth").mkdir(parents=True)

    (target / "README.md").write_text(README_MD)
    (target / "docs" / "architecture.md").write_text(ARCHITECTURE_MD)
    (target / "openspec" / "specs" / "auth" / "spec.md").write_text(SPEC_MD)
    (target / "openspec" / "changes" / "add-auth" / "proposal.md").write_text(PROPOSAL_MD)
    (target / "src" / "auth.js").write_text(AUTH_JS_V1)
    (target / "src" / "login.js").write_text(LOGIN_JS_V1)

    _run(["git", "init", "-q", "-b", "main"], cwd=target)
    _git_identity(target)
    _run(["git", "add", "README.md", "docs", "openspec", "src"], cwd=target)
    _run(["git", "commit", "-qm", "init"], cwd=target)

    # Second commit: Lua + Python, and a change to auth.js so there is a real diff.
    (target / "src" / "auth.js").write_text(AUTH_JS_V2)
    (target / "app.py").write_text(APP_PY)
    (target / "lib.lua").write_text(LIB_LUA)
    (target / ".nvim.lua").write_text(NVIM_LUA)

    _run(["git", "add", ".nvim.lua", "app.py", "lib.lua", "src/auth.js", "src/login.js"], cwd=target)
    _run(["git", "commit", "-qm", "add sources"], cwd=target)

    # Left uncommitted on purpose: git signs, hunk preview and the changed-files
    # picker all need a file that differs from HEAD.
    (target / "src" / "login.js").write_text(LOGIN_JS_V2)

    # Left untracked on purpose: git status and the explorer need untracked files.
    (target / "buggy.lua").write_text(BUGGY_LUA)
    (target / "broken.py").write_text(BROKEN_PY)
    (target / "messy.lua").write_text(MESSY_LUA)

    commits = _run(["git", "rev-list", "--count", "HEAD"], cwd=target).stdout.strip()
    tracked = _run(["git", "ls-files"], cwd=target).stdout.splitlines()
    untracked = _run(["git", "ls-files", "--others", "--exclude-standard"], cwd=target).stdout.splitlines()
    print(f"Fixture rebuilt at {target}")
    print(f"  {commits} commits, {len(tracked)} tracked, {len(untracked)} untracked")
    return target


# -- make-debug-fixtures.sh --------------------------------------------------

C_MAIN = """#include <stdio.h>

int add(int a, int b) {
  int sum = a + b;
  return sum;
}

int main(void) {
  int total = 0;
  for (int i = 1; i <= 5; i++) {
    total = add(total, i);
  }
  printf("total=%d\\n", total);
  return 0;
}
"""

CPP_MAIN = """#include <cstdio>
#include <vector>

int add(int a, int b) {
  int sum = a + b;
  return sum;
}

int main() {
  std::vector<int> xs{1, 2, 3, 4, 5};
  int total = 0;
  for (int x : xs) total = add(total, x);
  std::printf("total=%d\\n", total);
}
"""

RUST_MAIN = """fn add(a: i32, b: i32) -> i32 {
    let sum = a + b;
    sum
}

fn main() {
    let mut total = 0;
    for i in 1..=5 {
        total = add(total, i);
    }
    println!("total={}", total);
}
"""

PYTHON_MAIN = '''def add(a, b):
    total = a + b
    return total


def main():
    running = 0
    for i in range(1, 6):
        running = add(running, i)
    print(f"total={running}")


if __name__ == "__main__":
    main()
'''

TS_MAIN = """function add(a: number, b: number): number {
  const sum = a + b;
  return sum;
}

function main(): void {
  let total = 0;
  for (let i = 1; i <= 5; i++) {
    total = add(total, i);
  }
  console.log(`total=${total}`);
}

main();
"""

TS_PACKAGE_JSON = '{ "name": "debug-fixture", "version": "1.0.0" }\n'

JULIA_MAIN = """function add(a, b)
    total = a + b
    return total
end

function main()
    running = 0
    for i in 1:5
        running = add(running, i)
    end
    println("total=$running")
end

main()
"""

# Breakpoint line asserted on by name in check-debuggers.sh/-headless.sh's
# CASES tables (line 9, `const sum = a + b;`) -- do not shift anything above it.
TSX_INDEX = """function h(tag: string, props: Record<string, string> | null, ...children: string[]): HTMLElement {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(props ?? {})) element.setAttribute(name, value);
  for (const child of children) element.append(child);
  return element;
}

function add(a: number, b: number): number {
  const sum = a + b;
  return sum;
}

function App(): HTMLElement {
  let total = 0;
  for (let i = 1; i <= 5; i++) total = add(total, i);
  return <div id="total">{`total=${total}`}</div>;
}

document.body.append(App());

// Again every two seconds, so a debugger that attaches after load still has
// something to stop on.
setInterval(() => document.body.replaceChildren(App()), 2000);
"""

TSX_HTML = """<!doctype html>
<meta charset="utf-8">
<title>tsx fixture</title>
<!-- defer, or the script runs before there is a body to append to -->
<script defer src="index.js"></script>
"""

TSX_PACKAGE_JSON = """{
  "name": "tsx-fixture",
  "private": true,
  "scripts": {
    "dev": "python3 -m http.server --port 5599"
  }
}
"""


def _have(prog: str) -> bool:
    return shutil.which(prog) is not None


def _git_init(where: Path) -> None:
    if (where / ".git").is_dir():
        return
    _run(["git", "init", "-q", "-b", "main"], cwd=where)
    _git_identity(where)
    _run(["git", "add", "-A"], cwd=where)
    _run(["git", "commit", "-qm", "init"], cwd=where)


def build_debug_fixtures(dir: str | Path | None = None) -> tuple[list[str], list[str]]:
    target = Path(dir) if dir else HARNESS_DIR / "debug-fixtures"
    target.mkdir(parents=True, exist_ok=True)
    made: list[str] = []
    skipped: list[str] = []

    # C
    c_dir = target / "c"
    c_dir.mkdir(exist_ok=True)
    (c_dir / "main.c").write_text(C_MAIN)
    if _have("gcc") and _run(
        ["gcc", "-g", "-O0", "-o", str(c_dir / "hello"), str(c_dir / "main.c")], check=False
    ).returncode == 0:
        _git_init(c_dir)
        made.append("c")
    else:
        skipped.append("c: no gcc")

    # C++
    cpp_dir = target / "cpp"
    cpp_dir.mkdir(exist_ok=True)
    (cpp_dir / "main.cpp").write_text(CPP_MAIN)
    if _have("g++") and _run(
        ["g++", "-g", "-O0", "-o", str(cpp_dir / "hello"), str(cpp_dir / "main.cpp")], check=False
    ).returncode == 0:
        _git_init(cpp_dir)
        made.append("cpp")
    else:
        skipped.append("cpp: no g++")

    # Rust
    rust_dir = target / "rust"
    if _have("cargo"):
        if not (rust_dir / "Cargo.toml").is_file():
            _run(["cargo", "new", "--quiet", "--name", "debug_fixture", str(rust_dir)], check=False)
        (rust_dir / "src").mkdir(parents=True, exist_ok=True)
        (rust_dir / "src" / "main.rs").write_text(RUST_MAIN)
        if _run(["cargo", "build", "--quiet"], cwd=rust_dir, check=False).returncode == 0:
            _git_init(rust_dir)
            made.append("rust")
        else:
            skipped.append("rust: cargo build failed")
    else:
        skipped.append("rust: no cargo")

    # Python: the virtualenv is the point, since debugpy has to live in the
    # same interpreter the project runs.
    python_dir = target / "python"
    python_dir.mkdir(exist_ok=True)
    (python_dir / "main.py").write_text(PYTHON_MAIN)

    python_for_venv = None
    candidates = [shutil.which("python3") or ""]
    candidates += sorted(glob.glob(str(Path.home() / ".local/share/mise/installs/python/*/bin/python3")))
    for candidate in candidates:
        if not candidate or not os.access(candidate, os.X_OK):
            continue
        if _run([candidate, "-c", "import ensurepip"], check=False).returncode == 0:
            python_for_venv = candidate
            break

    if python_for_venv:
        venv_dir = python_dir / ".venv"
        if not venv_dir.is_dir():
            _run([python_for_venv, "-m", "venv", str(venv_dir)])
        pip = venv_dir / ("Scripts" if os.name == "nt" else "bin") / ("pip.exe" if os.name == "nt" else "pip")
        if _run([str(pip), "-q", "install", "debugpy"], check=False).returncode == 0:
            _git_init(python_dir)
            made.append("python")
        else:
            skipped.append("python: pip install debugpy failed")
    else:
        skipped.append("python: no python with ensurepip")

    # TypeScript. Node 22 strips types, so there is nothing to build.
    ts_dir = target / "typescript"
    ts_dir.mkdir(exist_ok=True)
    (ts_dir / "main.ts").write_text(TS_MAIN)
    (ts_dir / "package.json").write_text(TS_PACKAGE_JSON)
    if _have("node"):
        _git_init(ts_dir)
        made.append("typescript")
    else:
        skipped.append("typescript: no node")

    # Julia. DebugAdapter is a project dependency, so it goes in the project env.
    julia_dir = target / "julia"
    julia_dir.mkdir(exist_ok=True)
    (julia_dir / "main.jl").write_text(JULIA_MAIN)

    # A mise shim resolves its version from cwd, so outside a project that
    # names one it exits "No version is set for shim: julia" -- while
    # vim.fn.executable says yes to the shim regardless.
    if _have("mise"):
        mise_ls = _run(["mise", "ls", "julia"], check=False).stdout
        versions = [line.split()[1] for line in mise_ls.splitlines() if len(line.split()) > 1 and any(c.isdigit() for c in line)]
        if versions:
            (julia_dir / "mise.toml").write_text(f'[tools]\njulia = "{versions[0]}"\n')

    if _have("julia") and _run(
        ["julia", "--project=.", "-e", 'using Pkg; Pkg.add("DebugAdapter")'], cwd=julia_dir, check=False
    ).returncode == 0:
        _git_init(julia_dir)
        made.append("julia")
    else:
        skipped.append("julia: no julia, or DebugAdapter would not install")

    # TSX in a browser: the browser runs the compiled JS and the source map
    # puts the breakpoint back on the line you wrote. Compiled with the
    # vtsls compiler, since nothing else is installed for this.
    tsx_dir = target / "tsx"
    tsx_dir.mkdir(exist_ok=True)
    (tsx_dir / "index.tsx").write_text(TSX_INDEX)
    (tsx_dir / "index.html").write_text(TSX_HTML)
    (tsx_dir / "package.json").write_text(TSX_PACKAGE_JSON)

    data_dir = None
    if _have("nvim"):
        result = _run(
            ["nvim", "--headless",
             "+lua io.stdout:write(vim.fn.stdpath('data')) io.stdout:flush()", "+qa"],
            check=False,
        )
        data_dir = result.stdout.strip() or None
    if not data_dir:
        data_dir = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))
        data_dir = str(Path(data_dir) / os.environ.get("NVIM_APPNAME", "nvim"))

    tsc_matches = glob.glob(f"{data_dir}/mason/packages/vtsls/**/tsc.js", recursive=True)
    tsc_js = tsc_matches[0] if tsc_matches else None

    if _have("node") and tsc_js and _run(
        ["node", tsc_js, "--jsx", "react", "--jsxFactory", "h", "--sourceMap",
         "--target", "es2017", "--module", "none", "index.tsx"],
        cwd=tsx_dir, check=False,
    ).returncode == 0:
        _git_init(tsx_dir)
        made.append("tsx")
    else:
        skipped.append("tsx: no node, or no TypeScript compiler in mason")

    print(f"built: {' '.join(made) if made else 'none'}")
    if skipped:
        print("skipped:")
        for s in skipped:
            print(f"  {s}")
    print(f"in {target}")
    return made, skipped


def _cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="kind", required=True)

    p_fixture = sub.add_parser("fixture", help="build the git-repo fixture")
    p_fixture.add_argument("dir", nargs="?")
    p_fixture.add_argument("--force", action="store_true")

    p_debug = sub.add_parser("debug", help="build the per-language debug fixtures")
    p_debug.add_argument("dir", nargs="?")

    args = parser.parse_args()
    if args.kind == "fixture":
        build_fixture(args.dir, force=args.force)
    else:
        build_debug_fixtures(args.dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
