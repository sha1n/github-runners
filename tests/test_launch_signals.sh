#!/usr/bin/env bash
# Tests for launch.sh's own signal handling: the state its cleanup trap has to
# cope with when a signal arrives in the middle of starting the fleet.
#
# launch.sh records each runner in PIDS before it reads that runner's process
# group, so a signal landing in between leaves PGIDS one entry shorter than
# PIDS. Under `set -u` an unguarded read of the missing entry aborts cleanup
# mid-signal, which leaves behind the very orphans the trap exists to prevent.
#
# Sourcing launch.sh here is what the source guard at its foot is for; nothing
# in this file may call a helper that acts on $RUNNERS_DIR, which sourcing
# points back at the real fleet.
#
# Usage: ./tests/test_launch_signals.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_UNDER_TEST="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../launch.sh
source "$REPO_ROOT_UNDER_TEST/launch.sh"

FAILURES=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

test_signal_all_reaches_a_runner_with_no_recorded_group() {
  sleep 300 &
  local runner=$!
  PIDS=("$runner")
  PGIDS=()

  signal_all TERM
  local waited=0
  while kill -0 "$runner" 2>/dev/null && (( waited < 20 )); do
    sleep 0.1
    waited=$((waited + 1))
  done

  if kill -0 "$runner" 2>/dev/null; then
    fail "signal_all stops a runner whose group id was never recorded"
    kill -KILL "$runner" 2>/dev/null
  else
    pass "signal_all stops a runner whose group id was never recorded"
  fi
  # No `wait` here, on purpose: waiting on a child that a signal killed makes
  # Bash raise that same signal on itself, which would end the run right here.
}

test_any_running_sees_a_runner_with_no_recorded_group() {
  sleep 300 &
  local runner=$!
  PIDS=("$runner")
  PGIDS=()

  if any_running; then
    pass "any_running sees a runner whose group id was never recorded"
  else
    fail "any_running sees a runner whose group id was never recorded"
  fi

  kill -KILL "$runner" 2>/dev/null
}

test_signal_all_reaches_a_runner_with_no_recorded_group
test_any_running_sees_a_runner_with_no_recorded_group

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\nAll tests passed.\n'
  exit 0
else
  printf '\n%d test(s) failed.\n' "$FAILURES"
  exit 1
fi
