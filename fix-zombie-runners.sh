#!/usr/bin/env bash
# Detect and recover runners stuck in a "zombie" state: GitHub's broker still
# holds a session from a runner process that died without a clean shutdown
# (crash, SIGKILL, host sleep), so a fresh run.sh can never reconnect — it
# just loops forever on "TaskAgentSessionConflictException: Error: Conflict" /
# "A session for this runner already exists" in its _diag log.
#
# config.sh --replace (which register.sh already uses) clears the stuck
# session on GitHub's side, but only once ".runner_migrated" — a local
# broker-migration marker the runner writes, which config.sh treats as
# "already configured" even after .runner/.credentials are gone — is removed
# too. This script clears that local state, then delegates to register.sh
# (idempotent: it only touches runners lacking a .runner file) to redo the
# actual registration.
#
# Refuses to run while launch.sh is actively supervising the runners (defers
# to it, since killing them out from under it could interrupt a running
# job). If runner processes are alive but orphaned — launch.sh itself died
# without running its cleanup (crash, closed terminal) — stops them first,
# since nothing else is left to.
#
# Usage:
#   ./fix-zombie-runners.sh            detect + fix, then re-register via register.sh
#   ./fix-zombie-runners.sh --dry-run  show which runners are stuck, fix nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./fix-zombie-runners.sh [--dry-run]

  --dry-run   Show which runners are stuck, without deleting anything or
              contacting GitHub.
  -h, --help  Show this help.

Detects runners stuck with a stale GitHub broker session (visible in
runners/runner-N/_diag/*.log as "TaskAgentSessionConflictException" / "A
session for this runner already exists", with no later "Listening for Jobs").
For each one, clears the local files that block re-registration (.runner,
.credentials, .credentials_rsaparams, .runner_migrated) and hands off to
./register.sh, whose "--replace" registration clears the stuck session on
GitHub's side too.

Refuses to run while launch.sh is actively supervising the runners — stop it
first. If runner processes are alive but orphaned (launch.sh itself died —
crash, closed terminal — leaving them with no supervisor), this script stops
them itself before proceeding (skipped in --dry-run, which only reports them).
EOF
}

# Print the path to a runner dir's most recent Runner_*.log, if any (empty if
# none — e.g. a freshly registered runner that has never been launched).
# Filenames encode a fixed-width timestamp (Runner_YYYYMMDD-HHMMSS-utc.log),
# so a plain sort orders them chronologically. Uses nullglob rather than `ls`
# so a no-match glob doesn't fail the pipeline under set -o pipefail.
latest_runner_log() {
  local dir="$1" f
  local logs=()
  shopt -s nullglob
  for f in "$dir"/_diag/Runner_*.log; do
    logs+=("$f")
  done
  shopt -u nullglob
  [[ ${#logs[@]} -eq 0 ]] && return 0
  printf '%s\n' "${logs[@]}" | sort | tail -n1
}

# True if a runner's latest log's last relevant event is the stuck-session
# error, with no later successful connection — i.e. the last thing that
# happened to it was a broker conflict, not a clean run or a clean shutdown.
is_zombie() {
  local log="$1"
  [[ -n "$log" && -f "$log" ]] || return 1
  local last_conflict last_listening
  last_conflict="$(grep -n 'session for this runner already exists' "$log" | tail -n1 | cut -d: -f1)"
  [[ -n "$last_conflict" ]] || return 1
  last_listening="$(grep -n 'Listening for Jobs' "$log" | tail -n1 | cut -d: -f1)"
  [[ -n "$last_listening" && "$last_listening" -gt "$last_conflict" ]] && return 1
  return 0
}

main() {
  local dry_run=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  # Don't touch a runner's local state while it might be mid-retry. If
  # launch.sh is actively supervising the runners, defer to it. If launch.sh
  # is gone but runner processes remain (it crashed, its terminal was
  # closed, etc.), they're orphaned with nothing supervising them, so stop
  # them ourselves before proceeding.
  ensure_runners_stopped "$dry_run"

  [[ -d "$RUNNERS_DIR" ]] || die "no runners directory found at ${RUNNERS_DIR} — run ./register.sh first"

  local dirs=() d
  for d in "$RUNNERS_DIR"/runner-*; do
    [[ -d "$d" ]] && dirs+=("$d")
  done
  [[ ${#dirs[@]} -gt 0 ]] || die "no runner directories found in ${RUNNERS_DIR}"

  local zombies=() log
  for d in "${dirs[@]}"; do
    log="$(latest_runner_log "$d")"
    if is_zombie "$log"; then
      zombies+=("$d")
      info "$(basename "$d") is stuck (stale GitHub session — see $(basename "$log"))"
    fi
  done

  if [[ ${#zombies[@]} -eq 0 ]]; then
    info "No zombie runners found."
    exit 0
  fi

  if $dry_run; then
    info "Dry run — ${#zombies[@]} runner(s) would be cleared and re-registered."
    exit 0
  fi

  for d in "${zombies[@]}"; do
    info "Clearing local state for $(basename "$d")"
    rm -f "$d/.runner" "$d/.credentials" "$d/.credentials_rsaparams" "$d/.runner_migrated"
  done

  info "Re-registering ${#zombies[@]} runner(s) via register.sh..."
  "$SCRIPT_DIR/register.sh"
}

main "$@"
