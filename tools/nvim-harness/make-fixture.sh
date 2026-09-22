#!/usr/bin/env bash
# Build the fixture repository the gates run against. Generated rather than
# stored, so a fresh clone has a real git repo to test blame/signs/status
# against, with untracked and uncommitted files to show too.
#
# Usage:
#   make-fixture.sh [DIR]      default: the fixture beside this script
#
# Refuses to overwrite an existing fixture unless --force.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE=0
DIR=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) DIR="$arg" ;;
  esac
done
: "${DIR:=$HERE/fixture}"

if [[ -e "$DIR" && "$FORCE" -ne 1 ]]; then
  echo "$DIR already exists. Pass --force to rebuild it." >&2
  exit 2
fi

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }

rm -rf -- "$DIR"
mkdir -p "$DIR/src" "$DIR/docs" "$DIR/openspec/specs/auth" "$DIR/openspec/changes/add-auth"
cd "$DIR"

# First commit: docs + JS, so blame has something older than the rest.
cat > README.md <<'EOF'
# Fixture repo

Sample repo for picker comparisons. Mentions validateToken.
EOF

cat > docs/architecture.md <<'EOF'
# Architecture

Auth uses validateToken at the edge.
EOF

cat > openspec/specs/auth/spec.md <<'EOF'
# auth spec

## Requirement: validateToken
The system SHALL reject expired tokens.
EOF

cat > openspec/changes/add-auth/proposal.md <<'EOF'
# Add auth

This change adds token validation.
The validateToken helper checks expiry.
EOF

cat > src/auth.js <<'EOF'
function validateToken(token) {
  return token.expiresAt > Date.now();
}
EOF

cat > src/login.js <<'EOF'
export function login(user) {
  return validateToken(user.token);
}
EOF

git init -q -b main
git config user.email "fixture@example.invalid"
git config user.name "Fixture"
git add README.md docs openspec src
git commit -qm "init"

# Second commit: Lua + Python, and a change to auth.js so there is a real diff.
cat > src/auth.js <<'EOF'
// TODO: rotate signing keys on a schedule
// FIXME: expiry check is off by one at the boundary
function validateToken(token) {
  // token expiry check
  return token.expiresAt > Date.now();
}

function issueToken(user) {
  return { sub: user.id, expiresAt: Date.now() + 3600_000 };
}

module.exports = { validateToken, issueToken };
EOF

cat > app.py <<'EOF'
"""Sample module for the feature tour."""


def greet(name: str) -> str:
    # TODO: support localisation
    return f"hello {name}"


def main() -> None:
    print(greet("world"))
EOF

cat > lib.lua <<'EOF'
-- NOTE: used by the harness to show LSP features
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
EOF

cat > .nvim.lua <<'EOF'
-- Per-project settings for this repository, read by Neovim's exrc.
vim.g.search_filters = {
  docs = { "openspec/**" },
  presets = {
    { name = "specs", desc = "openspec specs only", globs = { "openspec/specs/**" } },
  },
}
EOF

git add .nvim.lua app.py lib.lua src/auth.js src/login.js
git commit -qm "add sources"

# Left uncommitted on purpose: git signs, hunk preview and the changed-files
# picker all need a file that differs from HEAD.
cat > src/login.js <<'EOF'
export function login(user) {
  return validateToken(user.token) && user.active;
}

// HACK: temporary shim, remove before release
module.exports.legacy = true;
EOF

# Left untracked on purpose: git status and the explorer need untracked files.
cat > buggy.lua <<'EOF'
-- NOTE: used by the harness to show the Claude review.
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
EOF

cat > broken.py <<'EOF'
"""Deliberately broken, so the diagnostics view has something to show."""


def compute(values):
    total = undefined_helper(values)
    return total / 0


def unused_import_demo():
    import os

    return 1
EOF

cat > messy.lua <<'EOF'
local M={}
function M.messy(  a,b )
      return a+b
end
return M
EOF

echo "Fixture rebuilt at $DIR"
echo "  $(git rev-list --count HEAD) commits, $(git ls-files | wc -l) tracked, $(git ls-files --others --exclude-standard | wc -l) untracked"
