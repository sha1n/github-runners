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

PIDS=()    # process id of each launched runner (the run.sh wrapper)
PGIDS=()   # matching process-group id, captured at launch time
CLEANED_UP=false
SELF_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"

# Recursively send a signal to a process and all of its descendants. Used as a
# fallback when job control is unavailable and we can't signal by group.
kill_tree() {
  local sig="$1" pid="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$sig" "$child"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# Send a signal to every runner. run.sh launches Runner.Listener as a *child*
# (not via exec), and during a job there are Worker/job processes too, so we
# must reach the whole subtree — signalling the lone run.sh pid is not enough.
# When the runner leads its own process group (the normal job-control case) we
# signal the group; otherwise we walk the process tree.
signal_all() {
  local sig="$1" i pg
  for i in "${!PIDS[@]}"; do
    pg="${PGIDS[$i]}"
    if [[ -n "$pg" && "$pg" != "$SELF_PGID" ]]; then
      kill -"$sig" "-$pg" 2>/dev/null || true
    else
      kill_tree "$sig" "${PIDS[$i]}"
    fi
  done
}

# True if any started runner (or a process in its group) is still alive.
any_running() {
  local i pg
  for i in "${!PIDS[@]}"; do
    pg="${PGIDS[$i]}"
    if [[ -n "$pg" && "$pg" != "$SELF_PGID" ]]; then
      kill -0 "-$pg" 2>/dev/null && return 0
    else
      kill -0 "${PIDS[$i]}" 2>/dev/null && return 0
    fi
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
  signal_all INT

  # Give them time to shut down gracefully, then escalate: SIGTERM, then
  # SIGKILL as a last resort, so nothing is ever left running in the background.
  local waited=0
  while any_running && (( waited < 20 )); do
    sleep 1
    waited=$((waited + 1))
  done
  if any_running; then
    warn "Some runners did not stop in time; sending SIGTERM."
    signal_all TERM
    waited=0
    while any_running && (( waited < 10 )); do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  if any_running; then
    warn "Runners still alive; forcing shutdown with SIGKILL."
    signal_all KILL
  fi

  local pid
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

  # Enable job control so each runner is placed in its own process group. This
  # is what makes a clean stop possible: background jobs started *without* job
  # control inherit SIG_IGN for SIGINT (and `trap -` only restores that ignored
  # disposition), so Ctrl+C would never reach the runner. With job control the
  # runner gets the default SIGINT handler and leads its own group, which we can
  # signal as a unit in cleanup().
  set -m

  for d in "${dirs[@]}"; do
    info "Starting $(basename "$d")"
    ( cd "$d" && exec ./run.sh ) &
    PIDS+=($!)
    PGIDS+=("$(ps -o pgid= -p $! 2>/dev/null | tr -d ' ')")
  done

  info "Started ${#dirs[@]} runner(s). Press Ctrl+C or Ctrl+D to stop."

  # Block until Ctrl+D (EOF) when interactive, or until the runners exit
  # otherwise. SIGINT/SIGTERM are handled by the trap. We poll with a
  # foreground `sleep` rather than a bare `wait` because, with job control
  # enabled, `wait` is not reliably interrupted by a trapped signal — the
  # sleep loop is, so cleanup always runs.
  if [[ -t 0 ]]; then
    while IFS= read -r _; do :; done
  else
    while any_running; do sleep 1; done
  fi

  cleanup
}

main "$@"
