#!/usr/bin/env bash
# Usage:
#   run-probes.sh -p PROJECT [-c CONFIG] [-n APPNAME] [-o OUTDIR] [-b BUDGET_MS] [-s SYMBOL]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
PROJECT=""
OUT="${TMPDIR:-/tmp}/nvim-probes"
BUDGET_MS=500
PARITY_SYMBOL=""

while getopts "p:c:n:o:b:s:" opt; do
  case "$opt" in
    p) PROJECT="$OPTARG" ;;
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    b) BUDGET_MS="$OPTARG" ;;
    s) PARITY_SYMBOL="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "-p PROJECT is required" >&2; exit 2; }
[[ -d "$PROJECT" ]] || { echo "No such project: $PROJECT" >&2; exit 2; }

mkdir -p "$OUT"

# Cleared: a report that did not run this time is otherwise a stale one.
rm -f "$OUT/stress.txt" "$OUT/perf.txt" "$OUT/parity.txt"

status=0

drive() {
  local probe_env="$1" probe_out="$2" probe_lua="$3" wait_secs="$4"
  local complaint
  complaint="$(mktemp)"
  env "$probe_env=$probe_out" "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$PROJECT" -t -w 90 -p "$wait_secs" \
    "ex:luafile $HERE/$probe_lua" >/dev/null 2>"$complaint" || true

  if [[ ! -s "$probe_out" && -s "$complaint" ]]; then
    echo "the driver said:"
    sed 's/^/  /' "$complaint"
  fi
  rm -f "$complaint"
}

report() {
  local title="$1" file="$2"
  echo
  echo "== $title =="
  if [[ -s "$file" ]]; then
    cat "$file"
  else
    echo "did not run"
    status=1
  fi
}

echo "project: $PROJECT"

drive NVIM_STRESS_OUT "$OUT/stress.txt" stress-probe.lua 12
report "what this project looks like" "$OUT/stress.txt"

if [[ -s "$OUT/stress.txt" ]]; then
  startup_errors="$(awk '$1 == "startup_errors" { print $2 }' "$OUT/stress.txt")"
  if [[ "${startup_errors:-0}" -gt 0 ]]; then
    echo
    echo "$startup_errors error(s) during startup."
    status=1
  fi
else
  status=1
fi

drive NVIM_PERF_OUT "$OUT/perf.txt" stress-perf.lua 12
report "how long the blocking calls take" "$OUT/perf.txt"

if [[ -s "$OUT/perf.txt" ]]; then
  over_budget="$(awk -v budget="$BUDGET_MS" '
    match($0, /[0-9]+\.[0-9]+ms/) {
      ms = substr($0, RSTART, RLENGTH - 2) + 0
      if (ms > budget) { print }
    }' "$OUT/perf.txt")"
  if [[ -n "$over_budget" ]]; then
    echo
    echo "over the ${BUDGET_MS}ms budget:"
    printf '%s\n' "$over_budget"
    status=1
  fi
else
  status=1
fi

if [[ -n "$PARITY_SYMBOL" ]]; then
  # A file containing the symbol is found and opened first, so there is a
  # real buffer for a language server to attach to.
  #
  # --include has to come before --: after -- ends option parsing, each
  # --include=* is read as a literal filename, and grep fails to open eight
  # files that were never files.
  #
  # `|| true`: grep exits 1 when nothing matches, which under pipefail would
  # otherwise end the script here, silently, before "no file under..." below
  # ever runs.
  parity_file="$(
    grep -rlF \
      --include='*.py' --include='*.ts' --include='*.tsx' --include='*.js' \
      --include='*.go' --include='*.rs' --include='*.lua' --include='*.rb' \
      -- "$PARITY_SYMBOL" "$PROJECT" \
      2>/dev/null | head -1
  )" || true
  # An if, not a bare `&&`: when nothing matched this would otherwise end
  # the script here under set -e, before the message below runs.
  if [[ -n "$parity_file" ]]; then
    parity_file="$(cd "$(dirname "$parity_file")" && pwd)/$(basename "$parity_file")"
  fi

  if [[ -z "$parity_file" ]]; then
    echo
    echo "== what each language server answers =="
    echo "no file under $PROJECT contains '$PARITY_SYMBOL'"
    status=1
  else
    env NVIM_LSP_PARITY_SYMBOL="$PARITY_SYMBOL" NVIM_LSP_PARITY_FILE="$parity_file" \
      NVIM_LSP_PARITY="$OUT/parity.txt" "$HERE/nvim-drive.sh" \
      -c "$CONFIG_ROOT" -n "$APPNAME" -d "$PROJECT" -t -w 90 -p 20 \
      "ex:luafile $HERE/lsp-parity.lua" >/dev/null 2>&1 || true
    report "what each language server answers" "$OUT/parity.txt"
  fi
fi

echo
echo "reports in $OUT"
exit "$status"
