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

REAL_RUNNERS_DIR="$REPO_ROOT_UNDER_TEST/runners"

# The helpers under test SIGKILL every process whose command line matches
# $RUNNERS_DIR, so a RUNNERS_DIR naming the real runners/ tree would kill a live
# fleet mid-job. This aborts the whole suite rather than letting any test act on
# such a value, and is deliberately stricter than an equality check: pgrep -f
# matches on substring, so "/runners" alone is just as lethal as the full path.
assert_runners_dir_is_disposable() {
  local reason=""
  if [[ -z "${RUNNERS_DIR:-}" ]]; then
    reason="it is empty"
  elif [[ "$RUNNERS_DIR" == "$REAL_RUNNERS_DIR" ]]; then
    reason="it names the real runner fleet"
  else
    case "$REAL_RUNNERS_DIR" in
      *"$RUNNERS_DIR"*) reason="pgrep -f would match the real runner fleet on it" ;;
    esac
    case "$RUNNERS_DIR" in
      "$REPO_ROOT_UNDER_TEST"/*) reason="it is inside the repository under test" ;;
    esac
  fi
  [[ -z "$reason" ]] && return 0
  printf 'FATAL: refusing to run with RUNNERS_DIR=%s — %s.\n' "${RUNNERS_DIR:-}" "$reason" >&2
  exit 99
}

# Sourcing lib/common.sh above set RUNNERS_DIR to the real fleet. Replace it
# before anything can act on it; each test then installs its own temp tree.
RUNNERS_DIR="${TMPDIR:-/tmp}/github-runners-tests-unset-$$/runners"
assert_runners_dir_is_disposable

# Same reasoning for the supervisor record: a test that wrote the real one would
# leave a live repository claiming a supervisor it does not have, which is
# enough to make unregister.sh refuse to run.
LAUNCH_PIDFILE="${TMPDIR:-/tmp}/github-runners-tests-unset-$$/launch.pid"

FAILURES=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# A run.sh -> helper.sh -> listener chain, none via exec, matching the real
# run.sh -> run-helper.sh -> Runner.Listener topology. Each hop is a distinct
# script file (not a forked function sharing the same argv) so runner_pids'
# pattern match on run.sh doesn't accidentally also catch its descendants.
#
# run.sh resolves its own directory and starts the helper by absolute path,
# because the real run.sh does exactly that ("$DIR"/run-helper.sh, with DIR from
# `cd -P "$(dirname "$SOURCE")" && pwd`). That is what makes a runner tree
# findable at all once launch.sh has started run.sh as `./run.sh`: the argv of
# run.sh itself then names no path, and only its children carry one.
make_mock_runner() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/run.sh" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd -P "$(dirname "$0")" && pwd)"
"$DIR/helper.sh" &
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

# The single way a test may point RUNNERS_DIR anywhere. A failed mktemp must
# abort rather than leave TMPDIR_TEST empty, which would aim every later pgrep
# at the bare string "/runners" — a substring of the real fleet's path.
use_temp_runners_dir() {
  TMPDIR_TEST="$(mktemp -d)" \
    || { printf 'FATAL: mktemp -d failed.\n' >&2; exit 99; }
  [[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] \
    || { printf 'FATAL: mktemp -d produced no usable directory.\n' >&2; exit 99; }
  RUNNERS_DIR="${TMPDIR_TEST:?}/runners"
  LAUNCH_PIDFILE="${TMPDIR_TEST:?}/launch.pid"
  assert_runners_dir_is_disposable
}

# The only place the suite kills anything, so the safety assertion sits on the
# one path that can do damage.
kill_mock_runners() {
  assert_runners_dir_is_disposable
  local pid
  for pid in $(runner_pids); do
    kill_tree KILL "$pid"
  done
}

setup() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"
  make_mock_runner "$RUNNERS_DIR/runner-2"
  "$RUNNERS_DIR/runner-1/run.sh" &
  "$RUNNERS_DIR/runner-2/run.sh" &
  sleep 0.3
}

teardown() {
  kill_mock_runners
  rm -rf "${TMPDIR_TEST:?}"
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

test_runners_supervised_false_when_absent() {
  use_temp_runners_dir
  ! runners_supervised && pass "runners_supervised is false with no launch.sh process" \
    || fail "runners_supervised is false with no launch.sh process"
  rm -rf "${TMPDIR_TEST:?}"
}

# The operator types "./launch.sh", so the real command line reads "bash
# ./launch.sh" — never an absolute path. A pgrep -f match on an absolute
# launch.sh path would miss this case entirely. tests/fixtures/launch.sh
# reproduces it: a script named launch.sh, run.sh started as its direct child,
# with no absolute-path match possible since the fixture lives outside
# $REPO_ROOT.
test_runners_supervised_true_for_relative_invocation() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"

  MOCK_RUNNERS="$RUNNERS_DIR/runner-1/run.sh" "$SCRIPT_DIR/fixtures/launch.sh" &
  local fake_launch=$!
  sleep 0.3

  runners_supervised && pass "runners_supervised is true for a relative-invocation supervisor" \
    || fail "runners_supervised is true for a relative-invocation supervisor"

  kill_mock_runners
  kill "$fake_launch" 2>/dev/null
  wait "$fake_launch" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

# launch.sh writes `( cd "$d" && exec ./run.sh ) &`, and whether the runner's
# command line ends up naming its directory is up to the shell: bash rewrites
# the path to an absolute one before it calls execve, zsh passes "./run.sh"
# through. The helpers must not depend on that. Going through env reproduces the
# path-less shape on any shell, and it is the shape with no margin: run.sh is
# then the top of the tree every stop path has to signal, and the process whose
# parent says whether a supervisor is present, while its own argv names nothing.
start_pathless_runner() {
  ( cd "$1" && exec env ./run.sh ) &
}

test_runner_pids_finds_a_run_sh_started_without_a_path() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"

  MOCK_RUNNERS="$RUNNERS_DIR/runner-1/run.sh" "$SCRIPT_DIR/fixtures/launch.sh" &
  local fake_launch=$!
  sleep 0.5

  local found expected
  found="$(runner_pids)"
  expected="$(pgrep -P "$fake_launch" 2>/dev/null | head -n1)"
  if [[ -n "$expected" && "$found" == "$expected" ]]; then
    pass "runner_pids finds a run.sh whose own command line names no path"
  else
    fail "runner_pids finds a run.sh whose own command line names no path (found '$found', expected '$expected')"
  fi

  kill_mock_runners
  kill "$fake_launch" 2>/dev/null
  wait "$fake_launch" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

# The stop path has the same blind spot as the detection path, and a worse
# consequence: run.sh restarts the helper every time it exits, so a sweep that
# reaches only the children never converges. Signalling has to reach the top.
test_stop_orphaned_runners_stops_a_run_sh_started_without_a_path() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"

  start_pathless_runner "$RUNNERS_DIR/runner-1"
  local top=$!
  sleep 0.5
  local child grandchild
  child="$(pgrep -P "$top" 2>/dev/null | head -n1)"
  grandchild="$(pgrep -P "$child" 2>/dev/null | head -n1)"

  if [[ -z "$child" || -z "$grandchild" ]]; then
    fail "stop_orphaned_runners stops a path-less run.sh (setup: mock tree did not start)"
  else
    stop_orphaned_runners
    if ! kill -0 "$top" 2>/dev/null \
       && ! kill -0 "$child" 2>/dev/null \
       && ! kill -0 "$grandchild" 2>/dev/null; then
      pass "stop_orphaned_runners stops a path-less run.sh, and its whole tree"
    else
      fail "stop_orphaned_runners stops a path-less run.sh, and its whole tree"
    fi
  fi

  kill_tree KILL "$top"
  kill_mock_runners
  wait "$top" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

test_runners_supervised_false_when_orphaned() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"

  # `( cmd & )`: the subshell forks run.sh, then exits immediately, so the
  # kernel reparents run.sh to pid 1 instead of leaving it a child of this
  # script — a genuine orphan, not just a parent whose name doesn't match.
  ( "$RUNNERS_DIR/runner-1/run.sh" & )

  local top waited=0
  top="$(runner_pids | head -n1)"
  while [[ -z "$top" ]] && (( waited < 20 )); do
    sleep 0.1
    top="$(runner_pids | head -n1)"
    waited=$((waited + 1))
  done
  if [[ -z "$top" ]]; then
    fail "runners_supervised is false when the mock runner is orphaned (mock runner never started)"
    kill_mock_runners
    rm -rf "${TMPDIR_TEST:?}"
    return
  fi

  waited=0
  local ppid
  ppid="$(ps -o ppid= -p "$top" 2>/dev/null | tr -d ' ')"
  while [[ "$ppid" != "1" ]] && (( waited < 20 )); do
    sleep 0.1
    ppid="$(ps -o ppid= -p "$top" 2>/dev/null | tr -d ' ')"
    waited=$((waited + 1))
  done
  if [[ "$ppid" != "1" ]]; then
    fail "runners_supervised is false when the mock runner is orphaned (mock runner did not reparent to pid 1 within timeout, ppid=$ppid)"
    kill_mock_runners
    rm -rf "${TMPDIR_TEST:?}"
    return
  fi

  runners_supervised && fail "runners_supervised is false when the mock runner is orphaned" \
    || pass "runners_supervised is false when the mock runner is orphaned"

  kill_mock_runners
  rm -rf "${TMPDIR_TEST:?}"
}

test_ensure_runners_stopped_noop_when_nothing_running() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"
  if ensure_runners_stopped false; then
    pass "ensure_runners_stopped is a no-op when nothing is running"
  else
    fail "ensure_runners_stopped is a no-op when nothing is running"
  fi
  rm -rf "${TMPDIR_TEST:?}"
}

test_ensure_runners_stopped_dies_when_launch_sh_supervising() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"

  MOCK_RUNNERS="$RUNNERS_DIR/runner-1/run.sh" "$SCRIPT_DIR/fixtures/launch.sh" &
  local fake_launch=$!
  sleep 0.3

  if ( ensure_runners_stopped false ) 2>/dev/null; then
    fail "ensure_runners_stopped dies when launch.sh is supervising"
  else
    pass "ensure_runners_stopped dies when launch.sh is supervising"
  fi

  kill_mock_runners
  kill "$fake_launch" 2>/dev/null
  wait "$fake_launch" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
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

# ensure_runners_stopped kills without prompting, without listing what it hit,
# and without leaving a record, so its reach must never exceed the set its own
# gate matched. The bystander here stands in for an operator inspecting the
# tree — a tail or an editor on a path under runners/ that is not a runner-N
# path — and it must survive a sweep aimed at orphaned runners.
#
# The orphan is a helper.sh with no run.sh above it, because that is the only
# state that reaches the rootless sweep at all: stop_orphaned_runners handles
# anything still rooted at a run.sh and the sweep is never entered.
test_ensure_runners_stopped_spares_non_runner_bystanders() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"
  printf '#!/usr/bin/env bash\nsleep 120\n' > "$RUNNERS_DIR/watch-diag.sh"
  chmod +x "$RUNNERS_DIR/watch-diag.sh"

  # Job control so these get the default SIGINT disposition; a plain background
  # job inherits SIG_IGN and would only die at the sweep's much later SIGTERM.
  set -m
  "$RUNNERS_DIR/runner-1/helper.sh" &
  local orphan=$!
  "$RUNNERS_DIR/watch-diag.sh" &
  local bystander=$!
  set +m
  sleep 0.5

  if ! kill -0 "$orphan" 2>/dev/null || ! kill -0 "$bystander" 2>/dev/null; then
    fail "ensure_runners_stopped spares a non-runner bystander (setup: processes did not start)"
  elif [[ -n "$(runner_pids)" ]]; then
    fail "ensure_runners_stopped spares a non-runner bystander (setup: a run.sh is present, so the sweep is never reached)"
  elif pgrep -f "$RUNNERS_DIR/runner-" 2>/dev/null | grep -qx "$bystander"; then
    fail "ensure_runners_stopped spares a non-runner bystander (setup: the bystander matches the gate, so it is not a bystander)"
  else
    ensure_runners_stopped false >/dev/null 2>&1
    if [[ -z "$(pgrep -f "$RUNNERS_DIR/runner-" 2>/dev/null)" ]] \
       && kill -0 "$bystander" 2>/dev/null; then
      pass "ensure_runners_stopped stops the orphan and spares a non-runner bystander"
    else
      fail "ensure_runners_stopped stops the orphan and spares a non-runner bystander (orphan gone=$(kill -0 "$orphan" 2>/dev/null && echo no || echo yes), bystander alive=$(kill -0 "$bystander" 2>/dev/null && echo yes || echo no))"
    fi
  fi

  kill_tree KILL "$bystander"
  kill_mock_runners
  wait "$bystander" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

test_nuke_runner_processes_kills_whole_tree() {
  setup
  local top child grandchild
  top="$(runner_pids | head -n1)"
  child="$(pgrep -P "$top" | head -n1)"
  grandchild="$(pgrep -P "$child" | head -n1)"

  local rc=0
  nuke_runner_processes || rc=$?

  if [[ "$rc" -eq 0 ]] \
     && [[ -z "$(runner_process_pids)" ]] \
     && ! kill -0 "$top" 2>/dev/null \
     && ! kill -0 "$child" 2>/dev/null \
     && ! kill -0 "$grandchild" 2>/dev/null; then
    pass "nuke_runner_processes stops every process in both trees and returns 0"
  else
    fail "nuke_runner_processes stops every process in both trees and returns 0 (rc=$rc)"
  fi
  teardown
}

# A sweep that decides what is left to kill by matching the pattern again on
# every poll can be held open forever by processes it never meant to kill,
# because a fresh one appears between one poll and the next. The sweep makes
# them itself: every `$(...)` it runs forks a subshell that carries the
# caller's argv until it execs, so a caller whose argv embeds $RUNNERS_DIR
# hands the pattern to each of its own forks. Linux pgrep -f reports them;
# macOS pgrep -f hides pgrep's own ancestors, which hides the whole effect
# there. tests/fixtures/churn.sh reproduces it on either system, and without
# the OS in the way: an unrelated process whose short-lived children each name
# $RUNNERS_DIR, none of which is a runner.
#
# The bound is the point of the assertion. An unfixed sweep still returns —
# after its full INT/TERM/KILL escalation runs out of patience, ~30s — so a
# test that only checks the return value passes on a sweep that never
# converged.
test_nuke_runner_processes_converges_while_matches_keep_appearing() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"

  CHURN_TOKEN="$RUNNERS_DIR/churn" "$SCRIPT_DIR/fixtures/churn.sh" &
  local churner=$!
  sleep 0.5

  local started=$SECONDS rc=0
  nuke_runner_processes || rc=$?
  local elapsed=$((SECONDS - started))

  kill_tree KILL "$churner"
  wait "$churner" 2>/dev/null

  if [[ "$rc" -eq 0 ]] && (( elapsed < 10 )); then
    pass "nuke_runner_processes converges while unrelated matches keep appearing"
  else
    fail "nuke_runner_processes converges while unrelated matches keep appearing (rc=$rc, took ${elapsed}s)"
  fi
  rm -rf "${TMPDIR_TEST:?}"
}

test_nuke_runner_processes_returns_zero_when_nothing_running() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"

  if nuke_runner_processes; then
    pass "nuke_runner_processes returns 0 when nothing is running"
  else
    fail "nuke_runner_processes returns 0 when nothing is running"
  fi
  rm -rf "${TMPDIR_TEST:?}"
}

# Two runners share one fake_launch parent so this actually exercises the
# de-dup path (both runner_pids entries resolve to the same ppid), not just
# the trivial single-runner case where "printed once" would hold regardless.
test_repo_launch_sh_pids_finds_supervisor() {
  use_temp_runners_dir
  make_mock_runner "$RUNNERS_DIR/runner-1"
  make_mock_runner "$RUNNERS_DIR/runner-2"

  MOCK_RUNNERS="$RUNNERS_DIR/runner-1/run.sh
$RUNNERS_DIR/runner-2/run.sh" "$SCRIPT_DIR/fixtures/launch.sh" &
  local fake_launch=$!
  sleep 0.5

  local found n
  found="$(repo_launch_sh_pids)"
  n="$(printf '%s\n' "$found" | grep -c .)"
  if [[ "$n" -eq 1 && "$found" == "$fake_launch" ]]; then
    pass "repo_launch_sh_pids finds the mock supervisor's pid exactly once"
  else
    fail "repo_launch_sh_pids finds the mock supervisor's pid exactly once (got '$found')"
  fi

  kill_mock_runners
  kill "$fake_launch" 2>/dev/null
  wait "$fake_launch" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

# Reproduces the trap the brief calls out by name: a caller whose own argv
# happens to embed $RUNNERS_DIR (e.g. invoked from inside it), which makes
# `pgrep -f "$RUNNERS_DIR"` match the caller itself. Runs nuke_runner_processes
# in a background subshell carrying that argv and asserts the subshell is
# still alive once it completes.
#
# A short fixed sleep is not enough to observe a broken exclusion: bash
# disables SIGINT/SIGQUIT by default for a background ('&') job, so a
# self-signalled SIGINT is silently ignored and the kill only lands ~10s
# later, at the SIGTERM stage of nuke_runner_processes' own escalation loop.
# So this polls for a completion marker the subshell writes right after
# nuke_runner_processes returns, up to a bound wide enough to cover that
# worst case, and treats "caller died before writing it" as its own explicit
# failure rather than letting a timeout fall through to a green assertion.
#
# NOTE: on macOS, `pgrep -f` (see pgrep(1) -a) excludes pgrep's own ancestors
# by default, and nuke_runner_processes always calls pgrep from within the
# caller's own process tree — so this scenario passes even if
# _nuke_target_pids' filtering is deleted entirely; the OS already protects
# the caller here. This test still documents and guards the real end-to-end
# safety property (a self-referential caller is never harmed). The exclusion
# logic itself is separately, and more strictly, covered by
# test_nuke_target_pids_excludes_given_pids, which is the one that actually
# goes red if the filtering breaks.
test_nuke_runner_processes_survives_self_referential_argv() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"
  local marker="$TMPDIR_TEST/nuke-returned"

  bash -c '
    source "'"$REPO_ROOT_UNDER_TEST"'/lib/common.sh"
    RUNNERS_DIR="'"$RUNNERS_DIR"'"
    nuke_runner_processes
    touch "'"$marker"'"
    sleep 5
  ' _ "$RUNNERS_DIR/self-marker" &
  local caller=$!

  local waited=0
  while [[ ! -e "$marker" ]] && kill -0 "$caller" 2>/dev/null && (( waited < 30 )); do
    sleep 0.5
    waited=$((waited + 1))
  done

  if [[ ! -e "$marker" ]]; then
    if kill -0 "$caller" 2>/dev/null; then
      fail "nuke_runner_processes does not kill a caller whose own argv embeds RUNNERS_DIR (timed out before it returned)"
    else
      fail "nuke_runner_processes does not kill a caller whose own argv embeds RUNNERS_DIR (caller was killed before it returned)"
    fi
  elif kill -0 "$caller" 2>/dev/null; then
    pass "nuke_runner_processes does not kill a caller whose own argv embeds RUNNERS_DIR"
  else
    fail "nuke_runner_processes does not kill a caller whose own argv embeds RUNNERS_DIR (caller died right after returning)"
  fi

  kill "$caller" 2>/dev/null
  wait "$caller" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

# Direct regression test for _nuke_target_pids' own filtering, independent of
# the OS-level protection that makes
# test_nuke_runner_processes_survives_self_referential_argv pass regardless:
# this one uses live mock-runner pids (real
# pgrep matches, not ancestors of this test process, so nothing here is
# auto-excluded by pgrep itself) and asserts the given pid is dropped while
# an unrelated matched pid survives. This is the one that actually goes red
# if the caller/parent exclusion is deleted from _nuke_target_pids.
test_nuke_target_pids_excludes_given_pids() {
  setup
  local all exclude_pid keep_pid filtered
  all="$(runner_process_pids)"
  exclude_pid="$(printf '%s\n' "$all" | sed -n '1p')"
  keep_pid="$(printf '%s\n' "$all" | sed -n '2p')"

  if [[ -z "$exclude_pid" || -z "$keep_pid" ]]; then
    fail "_nuke_target_pids excludes the given pid and keeps the rest (mock trees did not yield two matched pids)"
    teardown
    return
  fi

  filtered="$(_nuke_target_pids "$exclude_pid" "")"

  if ! printf '%s\n' "$filtered" | grep -qx "$exclude_pid" \
     && printf '%s\n' "$filtered" | grep -qx "$keep_pid"; then
    pass "_nuke_target_pids excludes the given pid and keeps the rest"
  else
    fail "_nuke_target_pids excludes the given pid and keeps the rest (filtered='$filtered')"
  fi
  teardown
}

# A supervisor whose runners have all exited on their own keeps waiting on
# stdin with no child left to be found through, and its own command line reads
# "./launch.sh" — nothing that names this repository. The record it writes when
# it starts is the only thing that still ties it here, and without it
# nuke-runners.sh reports a clean slate while the supervisor is still up.
test_repo_launch_sh_pids_finds_a_childless_launch_sh() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"

  "$SCRIPT_DIR/fixtures/launch.sh" &
  local fake_launch=$!
  printf '%s\n' "$fake_launch" > "$LAUNCH_PIDFILE"
  sleep 0.3

  local found
  found="$(repo_launch_sh_pids)"
  if [[ "$found" == "$fake_launch" ]]; then
    pass "repo_launch_sh_pids finds a launch.sh that has no runner left"
  else
    fail "repo_launch_sh_pids finds a launch.sh that has no runner left (got '$found')"
  fi

  kill "$fake_launch" 2>/dev/null
  wait "$fake_launch" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

# The record outlives the process that wrote it — a SIGKILLed launch.sh never
# clears it — so a pid that is merely present in the file proves nothing.
test_repo_launch_sh_pids_ignores_a_dead_record() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"

  sleep 0.1 &
  local dead=$!
  wait "$dead" 2>/dev/null

  printf '%s\n' "$dead" > "$LAUNCH_PIDFILE"
  local found
  found="$(repo_launch_sh_pids)"
  if [[ -z "$found" ]]; then
    pass "repo_launch_sh_pids ignores a record whose process is gone"
  else
    fail "repo_launch_sh_pids ignores a record whose process is gone (got '$found')"
  fi

  rm -rf "${TMPDIR_TEST:?}"
}

# The kernel hands out pid numbers again, so a stale record can name a live
# process that was never a launch.sh. Stopping that one would be a kill of an
# unrelated process, and reporting it as a supervisor would block unregister.sh
# on a supervisor that does not exist.
test_repo_launch_sh_pids_ignores_a_recycled_pid() {
  use_temp_runners_dir
  mkdir -p "$RUNNERS_DIR"

  sleep 300 &
  local impostor=$!
  printf '%s\n' "$impostor" > "$LAUNCH_PIDFILE"

  local found
  found="$(repo_launch_sh_pids)"
  if [[ -z "$found" ]]; then
    pass "repo_launch_sh_pids ignores a record whose pid now belongs to another process"
  else
    fail "repo_launch_sh_pids ignores a record whose pid now belongs to another process (got '$found')"
  fi

  kill "$impostor" 2>/dev/null
  wait "$impostor" 2>/dev/null
  rm -rf "${TMPDIR_TEST:?}"
}

test_runner_pids_finds_mock_trees
test_stop_orphaned_runners_kills_whole_tree
test_runner_pids_finds_a_run_sh_started_without_a_path
test_stop_orphaned_runners_stops_a_run_sh_started_without_a_path
test_runners_supervised_false_when_absent
test_runners_supervised_true_for_relative_invocation
test_runners_supervised_false_when_orphaned
test_ensure_runners_stopped_noop_when_nothing_running
test_ensure_runners_stopped_dies_when_launch_sh_supervising
test_ensure_runners_stopped_dry_run_reports_without_killing
test_ensure_runners_stopped_stops_orphans_when_not_dry_run
test_ensure_runners_stopped_spares_non_runner_bystanders
test_nuke_runner_processes_kills_whole_tree
test_nuke_runner_processes_returns_zero_when_nothing_running
test_nuke_runner_processes_converges_while_matches_keep_appearing
test_nuke_runner_processes_survives_self_referential_argv
test_nuke_target_pids_excludes_given_pids
test_repo_launch_sh_pids_finds_supervisor
test_repo_launch_sh_pids_finds_a_childless_launch_sh
test_repo_launch_sh_pids_ignores_a_dead_record
test_repo_launch_sh_pids_ignores_a_recycled_pid

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\nAll tests passed.\n'
  exit 0
else
  printf '\n%d test(s) failed.\n' "$FAILURES"
  exit 1
fi
