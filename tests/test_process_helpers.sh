#!/usr/bin/env bash
# Tests for the orphaned-runner process helpers in lib/common.sh: detecting
# and stopping runner processes left behind when launch.sh itself died
# (crash, closed terminal) without running its own cleanup trap.
#
# Exercised against a mock runner tree in a temp dir, per AGENTS.md's
# guidance for testing launch.sh-style signal handling (a run.sh that spawns
# children *not* via exec, so recursive signalling is actually exercised).
#
# Usage: ./tests/test_process_helpers.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_UNDER_TEST="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT_UNDER_TEST/lib/common.sh"

FAILURES=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# A run.sh -> helper.sh -> listener chain, none via exec, matching the real
# run.sh -> run-helper.sh -> Runner.Listener topology. Each hop is a distinct
# script file (not a forked function sharing the same argv) so runner_pids'
# pattern match on run.sh doesn't accidentally also catch its descendants.
make_mock_runner() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/run.sh" <<'EOF'
#!/usr/bin/env bash
"$(dirname "$0")/helper.sh" &
child=$!
trap 'kill "$child" 2>/dev/null; exit 0' INT TERM
wait "$child"
EOF
  cat > "$dir/helper.sh" <<'EOF'
#!/usr/bin/env bash
sleep 300 &
listener=$!
trap 'kill "$listener" 2>/dev/null; exit 0' INT TERM
wait "$listener"
EOF
  chmod +x "$dir/run.sh" "$dir/helper.sh"
}

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  RUNNERS_DIR="$TMPDIR_TEST/runners"
  make_mock_runner "$RUNNERS_DIR/runner-1"
  make_mock_runner "$RUNNERS_DIR/runner-2"
  "$RUNNERS_DIR/runner-1/run.sh" &
  "$RUNNERS_DIR/runner-2/run.sh" &
  sleep 0.3
}

teardown() {
  local pid
  for pid in $(runner_pids); do
    kill_tree KILL "$pid"
  done
  rm -rf "$TMPDIR_TEST"
}

test_runner_pids_finds_mock_trees() {
  setup
  local n
  n="$(runner_pids | grep -c .)"
  [[ "$n" -eq 2 ]] && pass "runner_pids finds both mock runner trees" \
    || fail "runner_pids finds both mock runner trees (got $n)"
  teardown
}

test_stop_orphaned_runners_kills_whole_tree() {
  setup
  local top child grandchild
  top="$(runner_pids | head -n1)"
  child="$(pgrep -P "$top" | head -n1)"
  grandchild="$(pgrep -P "$child" | head -n1)"

  stop_orphaned_runners

  if [[ -z "$(runner_pids)" ]] \
     && ! kill -0 "$top" 2>/dev/null \
     && ! kill -0 "$child" 2>/dev/null \
     && ! kill -0 "$grandchild" 2>/dev/null; then
    pass "stop_orphaned_runners stops every process in both trees"
  else
    fail "stop_orphaned_runners stops every process in both trees"
  fi
  teardown
}

test_launch_sh_running_false_when_absent() {
  ! launch_sh_running && pass "launch_sh_running is false with no launch.sh process" \
    || fail "launch_sh_running is false with no launch.sh process"
}

test_launch_sh_running_true_when_present() {
  ( exec -a "$REPO_ROOT/launch.sh" sleep 30 ) &
  local fake_pid=$!
  sleep 0.2
  launch_sh_running && pass "launch_sh_running is true when a launch.sh process exists" \
    || fail "launch_sh_running is true when a launch.sh process exists"
  kill "$fake_pid" 2>/dev/null
  wait "$fake_pid" 2>/dev/null
}

test_ensure_runners_stopped_noop_when_nothing_running() {
  TMPDIR_TEST="$(mktemp -d)"
  RUNNERS_DIR="$TMPDIR_TEST/runners"
  mkdir -p "$RUNNERS_DIR"
  if ensure_runners_stopped false; then
    pass "ensure_runners_stopped is a no-op when nothing is running"
  else
    fail "ensure_runners_stopped is a no-op when nothing is running"
  fi
  rm -rf "$TMPDIR_TEST"
}

test_ensure_runners_stopped_dies_when_launch_sh_supervising() {
  setup
  ( exec -a "$REPO_ROOT/launch.sh" sleep 30 ) &
  local fake_launch=$!
  sleep 0.2

  if ( ensure_runners_stopped false ) 2>/dev/null; then
    fail "ensure_runners_stopped dies when launch.sh is supervising"
  else
    pass "ensure_runners_stopped dies when launch.sh is supervising"
  fi

  kill "$fake_launch" 2>/dev/null
  wait "$fake_launch" 2>/dev/null
  teardown
}

test_ensure_runners_stopped_dry_run_reports_without_killing() {
  setup
  ensure_runners_stopped true >/dev/null
  if [[ -n "$(runner_pids)" ]]; then
    pass "ensure_runners_stopped --dry-run leaves orphaned processes alone"
  else
    fail "ensure_runners_stopped --dry-run leaves orphaned processes alone"
  fi
  teardown
}

test_ensure_runners_stopped_stops_orphans_when_not_dry_run() {
  setup
  ensure_runners_stopped false >/dev/null
  if [[ -z "$(runner_pids)" ]]; then
    pass "ensure_runners_stopped stops orphaned processes when not dry-run"
  else
    fail "ensure_runners_stopped stops orphaned processes when not dry-run"
  fi
  teardown
}

test_runner_pids_finds_mock_trees
test_stop_orphaned_runners_kills_whole_tree
test_launch_sh_running_false_when_absent
test_launch_sh_running_true_when_present
test_ensure_runners_stopped_noop_when_nothing_running
test_ensure_runners_stopped_dies_when_launch_sh_supervising
test_ensure_runners_stopped_dry_run_reports_without_killing
test_ensure_runners_stopped_stops_orphans_when_not_dry_run

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\nAll tests passed.\n'
  exit 0
else
  printf '\n%d test(s) failed.\n' "$FAILURES"
  exit 1
fi
