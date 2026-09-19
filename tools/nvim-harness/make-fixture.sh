#!/usr/bin/env bash
# Build the fixture repository the gates run against.
#
# `feature-tour.sh` and `check-keymaps.sh` both default to `fixture/`, and it
# was not in this repository: it holds a git repository of its own, so that
# blame, signs and status have something real to show, and a nested repository
# cannot be committed as plain files. The result was two gates that could not
# run on a fresh clone, and a README that told you to go and find the snippet
# in the history.
#
# So it is generated instead of stored. That also makes the interesting part
# explicit rather than accidental: the two commits, which files are tracked in
# which, and which are left untracked on purpose.
#
# What the content is for:
#
#   validateToken     the search term every picker scenario looks for. It
#                     appears in code, in a spec, in a proposal and in a
#                     README, so the documentation filters have something to
#                     include and exclude.
#   buggy.lua         one defect per function, so a review that finds nothing
#                     is a broken review rather than clean code.
#   broken.py         an undefined name and a division by zero, so the
#                     diagnostics view is never empty.
#   messy.lua         badly formatted on purpose, for the formatter.
#   .nvim.lua         a project tier that narrows `docs` to openspec only, so
#                     the settings tiers can be seen doing something.
#
# The last three are deliberately left untracked, so `git status` and the
# explorer have untracked files to show.
#
# Usage:
#   make-fixture.sh [DIR]      default: the fixture beside this script
#
# Refuses to overwrite an existing fixture unless --force, because the local
# copy may have been edited while chasing something.
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

# The first commit: the documentation and the JavaScript, so that blame has
# something older than the rest.
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

# The second commit: the Lua and Python, and a change to auth.js so there is a
# diff between two commits rather than only an initial import.
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

cat > src/login.js <<'EOF'
export function login(user) {
  return validateToken(user.token);
}

// HACK: temporary shim, remove before release
module.exports.legacy = true;
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
--
-- Here only the openspec tree counts as documentation. Markdown elsewhere,
-- such as README.md, is treated as code and stays in the default search.
vim.g.search_filters = {
  docs = { "openspec/**" },
  presets = {
    { name = "specs", desc = "openspec specs only", globs = { "openspec/specs/**" } },
  },
}
EOF

git add .nvim.lua app.py lib.lua src/auth.js src/login.js
git commit -qm "add sources"

# Left untracked on purpose: git status and the explorer need untracked files,
# and nothing should be tempted to "fix" these into the history.
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
