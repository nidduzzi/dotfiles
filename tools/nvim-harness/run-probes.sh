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

# Cleared, because a report that did not run this time is a report from
# whenever it last did. The fixture run printed label-studio's 5626 tracked
# files, taken from a stress.txt written days earlier, and read as if the
# fixture had them.
rm -f "$OUT/stress.txt" "$OUT/perf.txt" "$OUT/parity.txt"

status=0

drive() {
  local probe_env="$1" probe_out="$2" probe_lua="$3" wait_secs="$4"
  # stderr is kept. The driver refused to start once, with "FORCE_TRUST:
  # unbound variable", and this reported "did not run" -- which is true and
  # says nothing about why.
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
  env NVIM_LSP_PARITY_SYMBOL="$PARITY_SYMBOL" \
    NVIM_LSP_PARITY="$OUT/parity.txt" "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$PROJECT" -t -w 90 -p 20 \
    "ex:luafile $HERE/lsp-parity.lua" >/dev/null 2>&1 || true
  report "what each language server answers" "$OUT/parity.txt"
fi

echo
echo "reports in $OUT"
exit "$status"
