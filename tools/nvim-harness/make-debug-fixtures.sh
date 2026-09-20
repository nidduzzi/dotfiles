#!/usr/bin/env bash
# Build the small programs the debugger films and probes run against.
#
# One per language, each with a function taking two arguments and a local, so a
# breakpoint on that line has something to show in the variables pane.
#
# Usage:
#   make-debug-fixtures.sh [DIR]      default: debug-fixtures beside this script
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-$HERE/debug-fixtures}"

mkdir -p "$DIR"

made=()
skipped=()

have() { command -v "$1" >/dev/null; }

git_init() {
  local where="$1"
  [[ -d "$where/.git" ]] && return 0
  git -C "$where" init -q -b main
  git -C "$where" config user.email "fixture@example.invalid"
  git -C "$where" config user.name "Fixture"
  git -C "$where" add -A
  git -C "$where" commit -qm "init"
}

# C
mkdir -p "$DIR/c"
cat > "$DIR/c/main.c" <<'EOF'
#include <stdio.h>

int add(int a, int b) {
  int sum = a + b;
  return sum;
}

int main(void) {
  int total = 0;
  for (int i = 1; i <= 5; i++) {
    total = add(total, i);
  }
  printf("total=%d\n", total);
  return 0;
}
EOF
if have gcc && gcc -g -O0 -o "$DIR/c/hello" "$DIR/c/main.c" 2>/dev/null; then
  git_init "$DIR/c"
  made+=("c")
else
  skipped+=("c: no gcc")
fi

# C++
mkdir -p "$DIR/cpp"
cat > "$DIR/cpp/main.cpp" <<'EOF'
#include <cstdio>
#include <vector>

int add(int a, int b) {
  int sum = a + b;
  return sum;
}

int main() {
  std::vector<int> xs{1, 2, 3, 4, 5};
  int total = 0;
  for (int x : xs) total = add(total, x);
  std::printf("total=%d\n", total);
}
EOF
if have g++ && g++ -g -O0 -o "$DIR/cpp/hello" "$DIR/cpp/main.cpp" 2>/dev/null; then
  git_init "$DIR/cpp"
  made+=("cpp")
else
  skipped+=("cpp: no g++")
fi

# Rust
if have cargo; then
  [[ -f "$DIR/rust/Cargo.toml" ]] || cargo new --quiet --name debug_fixture "$DIR/rust" 2>/dev/null || true
  cat > "$DIR/rust/src/main.rs" <<'EOF'
fn add(a: i32, b: i32) -> i32 {
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
EOF
  if (cd "$DIR/rust" && cargo build --quiet 2>/dev/null); then
    git_init "$DIR/rust"
    made+=("rust")
  else
    skipped+=("rust: cargo build failed")
  fi
else
  skipped+=("rust: no cargo")
fi

# Python. The virtualenv is the point: the debugger runs the project's own
# interpreter, so debugpy has to be in it.
mkdir -p "$DIR/python"
cat > "$DIR/python/main.py" <<'EOF'
def add(a, b):
    total = a + b
    return total


def main():
    running = 0
    for i in range(1, 6):
        running = add(running, i)
    print(f"total={running}")


if __name__ == "__main__":
    main()
EOF
python_for_venv=""
for candidate in "$(command -v python3 || true)" "$HOME/.local/share/mise/installs/python/"*/bin/python3; do
  [[ -x "$candidate" ]] || continue
  if "$candidate" -c "import ensurepip" 2>/dev/null; then
    python_for_venv="$candidate"
    break
  fi
done

if [[ -n "$python_for_venv" ]]; then
  [[ -d "$DIR/python/.venv" ]] || "$python_for_venv" -m venv "$DIR/python/.venv"
  if "$DIR/python/.venv/bin/python" -m pip -q install debugpy 2>/dev/null; then
    git_init "$DIR/python"
    made+=("python")
  else
    skipped+=("python: pip install debugpy failed")
  fi
else
  skipped+=("python: no python with ensurepip")
fi

# TypeScript. Node 22 strips types, so there is nothing to build.
mkdir -p "$DIR/typescript"
cat > "$DIR/typescript/main.ts" <<'EOF'
function add(a: number, b: number): number {
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
EOF
printf '{ "name": "debug-fixture", "version": "1.0.0" }\n' > "$DIR/typescript/package.json"
if have node; then
  git_init "$DIR/typescript"
  made+=("typescript")
else
  skipped+=("typescript: no node")
fi

# Julia. DebugAdapter is a dependency of the project, not a tool the editor
# installs, so it goes in the project environment.
mkdir -p "$DIR/julia"
cat > "$DIR/julia/main.jl" <<'EOF'
function add(a, b)
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
EOF
# A mise shim resolves the version from the directory it runs in, so a shim on
# PATH is not the same as a usable interpreter: outside a project that names a
# version it exits with "No version is set for shim: julia". The editor asks
# vim.fn.executable, which says yes to the shim either way, and the debug
# session then failed with nothing on screen to say why.
if have mise && mise ls julia 2>/dev/null | grep -q '[0-9]'; then
  julia_version="$(mise ls julia 2>/dev/null | awk '/[0-9]/ { print $2; exit }')"
  printf '[tools]\njulia = "%s"\n' "$julia_version" > "$DIR/julia/mise.toml"
fi

if have julia && (cd "$DIR/julia" && julia --project=. -e 'using Pkg; Pkg.add("DebugAdapter")' >/dev/null 2>&1); then
  git_init "$DIR/julia"
  made+=("julia")
else
  skipped+=("julia: no julia, or DebugAdapter would not install")
fi

# TSX in a browser, which is how TSX is really debugged: the browser runs the
# compiled JavaScript and the source map is what puts the breakpoint back on
# the line you wrote. The compiler is the one vtsls ships, so nothing is
# installed for this; the JSX factory is a local function so no framework is
# either.
mkdir -p "$DIR/tsx"
cat > "$DIR/tsx/index.tsx" <<'EOF'
function h(tag: string, props: Record<string, string> | null, ...children: string[]): HTMLElement {
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
EOF
cat > "$DIR/tsx/index.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>tsx fixture</title>
<script src="index.js"></script>
EOF
cat > "$DIR/tsx/package.json" <<'EOF'
{
  "name": "tsx-fixture",
  "private": true,
  "scripts": {
    "dev": "python3 -m http.server --port 5599"
  }
}
EOF
tsc_js="$(find "${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}/mason/packages/vtsls" -name tsc.js 2>/dev/null | head -1)"
if have node && [[ -n "$tsc_js" ]] &&
  (cd "$DIR/tsx" && node "$tsc_js" --jsx react --jsxFactory h --sourceMap --target es2017 --module none index.tsx >/dev/null 2>&1); then
  git_init "$DIR/tsx"
  made+=("tsx")
else
  skipped+=("tsx: no node, or no TypeScript compiler in mason")
fi

echo "built: ${made[*]:-none}"
[[ ${#skipped[@]} -gt 0 ]] && printf 'skipped:\n%s\n' "$(printf '  %s\n' "${skipped[@]}")"
echo "in $DIR"
