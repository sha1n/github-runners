#!/usr/bin/env bash
# Last-resort recovery for the case no signal trap can cover: the terminal
# holding launch.sh was killed with SIGKILL, or the machine lost power.
# Runner processes then survive as orphans, and each surviving
# Runner.Listener keeps its GitHub broker session alive — so the next
# launch.sh gets "HTTP Status: Conflict" / "A session for this runner
# already exists" forever, because the session is live, not stale.
#
# Unlike fix-zombie-runners.sh, which refuses to run while a launch.sh is
# present (it defers to it, so it never interrupts a running job), this
# script never defers: that refusal is exactly what leaves the operator
# stuck. It stops any launch.sh it finds first, then sweeps every process
# under $RUNNERS_DIR. Use it only when you intend to discard whatever
# launch.sh and its runners were doing.
#
# Contacts no network, needs no credential, and changes no file on disk — it
# only signals processes, and runners stay registered with GitHub. Where the
# sweep ends at SIGINT the listeners close their broker sessions and ./launch.sh
# works immediately; where it has to escalate to SIGKILL a session can be left
# stale on GitHub's side, which surfaces as a conflict on the next launch and is
# what ./fix-zombie-runners.sh clears.
#
# Usage:
#   ./nuke-runners.sh            confirm, then stop launch.sh and all runner processes
#   ./nuke-runners.sh --dry-run  show what would be stopped, stop nothing
#   ./nuke-runners.sh --yes      skip the confirmation prompt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./nuke-runners.sh [--dry-run] [--yes]

  --dry-run   List what would be stopped, and stop nothing.
  --yes, -y   Skip the confirmation prompt.
  -h, --help  Show this help.
EOF
}

# Print each pid in a newline-separated list with its current command line,
# or "(none)" if the list is empty. A pid can exit between collection and
# display; ps then exits non-zero with no output, which errexit would turn
# into a silent abort mid-listing — so absorb that and show a placeholder.
print_pid_list() {
  local pids="$1" pid line
  if [[ -z "$pids" ]]; then
    printf '    (none)\n'
    return 0
  fi
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    printf '    %s  %s\n' "$pid" "${line:-<gone>}"
  done <<< "$pids"
}

# How long to let a signalled launch.sh finish before killing it. launch.sh's
# own cleanup escalates SIGINT -> SIGTERM -> SIGKILL across up to 30s before it
# returns, so anything shorter SIGKILLs it mid-shutdown on essentially every
# run. That is worth waiting out rather than tuning away: a listener killed
# before it closes its broker session leaves the stale session
# fix-zombie-runners.sh exists to clear, whereas letting launch.sh finish stops
# its runners cleanly.
LAUNCH_SH_STOP_TIMEOUT=35

# Stop every pid in a newline-separated list: TERM, wait, then KILL.
# Used only for launch.sh itself — nuke_runner_processes handles the runner
# processes with its own INT/TERM/KILL escalation.
stop_pids() {
  local pids="$1" pid waited
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    info "Stopping launch.sh (pid $pid) — waiting up to ${LAUNCH_SH_STOP_TIMEOUT}s for it to stop its own runners"
    kill -TERM "$pid" 2>/dev/null || true
    waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < LAUNCH_SH_STOP_TIMEOUT )); do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      warn "launch.sh (pid $pid) did not stop in time; killing"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done <<< "$pids"
}

# Pids from a newline-separated list that are still alive, space-separated.
alive_pids() {
  local pids="$1" pid out=""
  [[ -n "$pids" ]] || { printf ''; return 0; }
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -0 "$pid" 2>/dev/null && out="$out $pid"
  done <<< "$pids"
  printf '%s' "$out"
}

main() {
  local dry_run=false assume_yes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --yes|-y)  assume_yes=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  load_env

  local supervisor_pids runner_pids_list
  supervisor_pids="$(repo_launch_sh_pids)"
  runner_pids_list="$(runner_process_pids)"

  echo "launch.sh supervisor(s):"
  print_pid_list "$supervisor_pids"
  echo "Runner processes (run.sh, run-helper.sh, Runner.Listener, Runner.Worker):"
  print_pid_list "$runner_pids_list"
  echo

  if [[ -z "$supervisor_pids" && -z "$runner_pids_list" ]]; then
    info "No launch.sh or runner processes found — nothing to do."
    exit 0
  fi

  if $dry_run; then
    info "Dry run — nothing was stopped."
    exit 0
  fi

  if ! $assume_yes; then
    printf 'Proceed? [y/N] '
    local reply=""
    read -r reply || true
    case "$reply" in
      y|Y|yes|Yes) ;;
      *) die "aborted." ;;
    esac
  fi

  # Stop the supervisor(s) first: a launch.sh left alive during the sweep
  # could start relaunching a runner it thinks just exited.
  stop_pids "$supervisor_pids"

  nuke_runner_processes || true

  local surviving_supervisors surviving_runners
  surviving_supervisors="$(alive_pids "$supervisor_pids")"
  surviving_runners="$(runner_process_pids | tr '\n' ' ')"

  if [[ -n "$surviving_supervisors" || -n "${surviving_runners// /}" ]]; then
    die "processes survived the sweep — launch.sh:${surviving_supervisors:- none}; runner processes: ${surviving_runners:-none}"
  fi

  info "All clear — no launch.sh or runner processes remain."
  info "Try ./launch.sh next. If it reports a session conflict, a listener was"
  info "killed before it closed its broker session — run ./fix-zombie-runners.sh first."
}

main "$@"
