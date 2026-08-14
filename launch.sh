#!/usr/bin/env bash
# Start every registered runner, then stop them all cleanly on Ctrl+C (SIGINT),
# Ctrl+D (EOF on stdin), Ctrl+\ (SIGQUIT), a closed terminal (SIGHUP), or any
# error exit. Runners stay registered with GitHub — only the local processes are
# stopped, so the next launch is instant.
#
# A SIGKILL of this script or a power loss still leaves runner processes behind,
# since neither gives it a chance to stop them; ./nuke-runners.sh clears those.
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

# kill_tree (used as a fallback when job control is unavailable and we can't
# signal by group) comes from lib/common.sh, sourced above.

# Send a signal to every runner. run.sh launches Runner.Listener as a *child*
# (not via exec), and during a job there are Worker/job processes too, so we
# must reach the whole subtree — signalling the lone run.sh pid is not enough.
# When the runner leads its own process group (the normal job-control case) we
# signal the group; otherwise we walk the process tree.
#
# A runner is appended to PIDS before its group id is read, so a signal that
# arrives in between leaves PGIDS one entry short. This reader and any_running
# both treat a missing group the same way they treat an unreadable one, and walk
# the tree instead; under `set -u` an unguarded read would abort the stop.
signal_all() {
  local sig="$1" i pg
  for i in "${!PIDS[@]}"; do
    pg="${PGIDS[$i]:-}"
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
    pg="${PGIDS[$i]:-}"
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
  # Withdraw the supervisor record first, so it is gone even on the paths that
  # stop here: the record outliving this process is what makes a recovery script
  # report a supervisor that no longer exists.
  clear_launch_sh_pid

  # No runner has been recorded yet, so there is nothing to stop. This is
  # reached when a signal arrives after the traps are installed but before the
  # first runner is appended, and the guard is what keeps that case quiet:
  # expanding an empty array as "${PIDS[@]}" is an unbound-variable error under
  # `set -u` in Bash 3.2.
  [[ ${#PIDS[@]} -eq 0 ]] && return 0
  $CLEANED_UP && return 0
  CLEANED_UP=true

  # A hung-up terminal makes every write to it fail with EIO, and under errexit
  # the first failing write would abort this function before a single runner is
  # signalled — leaving exactly the orphans this trap exists to prevent. The
  # relaxation leaks to the caller by design: every call site either exits
  # immediately afterwards or is the last statement of main.
  set +e

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

  # A previous launch.sh may have died without stopping its runners. Those
  # orphans keep their GitHub broker session alive, so starting a second
  # Runner.Listener from the same directory is rejected with a session
  # conflict forever. Clearing them here makes a plain restart self-healing.
  ensure_runners_stopped false

  # Discover configured runners (extracted and registered).
  local dirs=() d
  if [[ -d "$RUNNERS_DIR" ]]; then
    for d in "$RUNNERS_DIR"/runner-*; do
      [[ -d "$d" && -f "$d/.runner" && -x "$d/run.sh" ]] && dirs+=("$d")
    done
  fi
  [[ ${#dirs[@]} -gt 0 ]] \
    || die "no configured runners found in ${RUNNERS_DIR} — run ./register.sh first"

  # SIGHUP is what a closed terminal delivers and SIGQUIT what Ctrl+\ sends.
  # Untrapped, either one kills this script while the runners, each leading its
  # own process group, survive as orphans. The EXIT trap covers the remaining
  # ways out, including an error exit under `set -e`.
  trap 'cleanup; exit 130' INT TERM HUP QUIT
  trap cleanup EXIT

  # Say who is supervising this fleet, now that a trap exists to withdraw it
  # again. Once every runner has exited, this record is all that is left to find
  # this process by: it is still holding the terminal, still about to be told by
  # ./nuke-runners.sh that nothing is running.
  record_launch_sh_pid

  # Enable job control so each runner is placed in its own process group. This
  # is what makes a clean stop possible: background jobs started *without* job
  # control inherit SIG_IGN for SIGINT (and `trap -` only restores that ignored
  # disposition), so Ctrl+C would never reach the runner. With job control the
  # runner gets the default SIGINT handler and leads its own group, which we can
  # signal as a unit in cleanup().
  set -m

  local pid pgid
  for d in "${dirs[@]}"; do
    info "Starting $(basename "$d")"
    ( cd "$d" && exec ./run.sh ) &
    pid=$!
    # Record the runner before reading anything about it. The traps are already
    # installed, and Bash runs a pending trap between commands, so a Ctrl+C
    # landing while `ps` runs would otherwise send cleanup off with this runner
    # missing from PIDS — it would exit and leave behind exactly the orphan the
    # trap exists to prevent.
    PIDS+=("$pid")
    # A runner that died on the spot leaves no group to read. Tolerate that: the
    # readers walk the process tree when the group is unknown, and the two
    # arrays must stay index-aligned or one would read a group id belonging to a
    # different runner.
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    PGIDS+=("$pgid")
  done

  info "Started ${#dirs[@]} runner(s). Press Ctrl+C or Ctrl+D to stop."

  # Block until Ctrl+D (EOF) when interactive, or until the runners exit
  # otherwise. SIGINT/SIGTERM/SIGHUP are handled by the trap. We poll with a
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

# Only launch anything when this file is run, so that a test can source it for
# its signal handling without starting the real fleet.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
