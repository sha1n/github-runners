#!/usr/bin/env bash
# Start every registered runner, then stop them all cleanly on Ctrl+C (SIGINT)
# or Ctrl+D (EOF on stdin). Runners stay registered with GitHub — only the
# local processes are stopped, so the next launch is instant.
#
# Usage:
#   ./launch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PIDS=()
CLEANED_UP=false

# True if any started runner process is still alive.
any_running() {
  local pid
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# Gracefully stop all runners. Idempotent — safe to call from a trap and again
# from the normal exit path.
cleanup() {
  $CLEANED_UP && return 0
  CLEANED_UP=true

  printf '\n'
  info "Stopping runners..."
  local pid
  for pid in "${PIDS[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
  done

  # Give them time to shut down gracefully, then escalate to SIGTERM.
  local waited=0
  while any_running && (( waited < 20 )); do
    sleep 1
    waited=$((waited + 1))
  done
  if any_running; then
    warn "Some runners did not stop in time; sending SIGTERM."
    for pid in "${PIDS[@]}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
  fi

  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  info "All runners stopped. They remain registered."
}

main() {
  load_env

  # Discover configured runners (extracted and registered).
  local dirs=() d
  if [[ -d "$RUNNERS_DIR" ]]; then
    for d in "$RUNNERS_DIR"/runner-*; do
      [[ -d "$d" && -f "$d/.runner" && -x "$d/run.sh" ]] && dirs+=("$d")
    done
  fi
  [[ ${#dirs[@]} -gt 0 ]] \
    || die "no configured runners found in ${RUNNERS_DIR} — run ./register.sh first"

  trap 'cleanup; exit 130' INT TERM

  for d in "${dirs[@]}"; do
    info "Starting $(basename "$d")"
    # Reset INT/TERM to default in the child before exec so the runner's own
    # signal handling works even though background jobs inherit SIG_IGN.
    ( trap - INT TERM; cd "$d" && exec ./run.sh ) &
    PIDS+=($!)
  done

  info "Started ${#dirs[@]} runner(s). Press Ctrl+C or Ctrl+D to stop."

  # Block until Ctrl+D (EOF) when interactive, or until the runners exit /
  # a signal arrives otherwise. SIGINT/SIGTERM are handled by the trap.
  if [[ -t 0 ]]; then
    while IFS= read -r _; do :; done
  else
    wait
  fi

  cleanup
}

main "$@"
