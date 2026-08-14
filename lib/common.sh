#!/usr/bin/env bash
# Shared helpers for the self-hosted runner scripts.
# Sourced by register.sh and launch.sh — not meant to be run directly.

# Resolve repo root (the dir containing this lib/) regardless of caller's cwd.
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_SH_DIR/.." && pwd)"
# These are consumed by the sourcing scripts.
# shellcheck disable=SC2034
RUNNERS_DIR="$REPO_ROOT/runners"
# shellcheck disable=SC2034
CACHE_DIR="$REPO_ROOT/.cache"

# --- logging -----------------------------------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- config ------------------------------------------------------------------

# Source .env from the repo root if it exists, exporting every assignment.
load_env() {
  local env_file="$REPO_ROOT/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi
}

# Validate the non-secret config register.sh needs. The credential
# (RUNNER_TOKEN / gh) is resolved separately, at run time.
require_vars() {
  [[ -n "${GITHUB_ORG:-}" ]] || die "GITHUB_ORG is not set (copy .env.example to .env)"
  [[ "${RUNNER_COUNT:-}" =~ ^[1-9][0-9]*$ ]] \
    || die "RUNNER_COUNT must be a positive integer (got '${RUNNER_COUNT:-}')"
}

# Warn if a secret is stored in .env. Secrets belong in the shell environment,
# not on disk; .env should hold only non-secret config.
warn_if_secret_in_env() {
  local env_file="$REPO_ROOT/.env"
  [[ -f "$env_file" ]] || return 0
  if grep -qE '^[[:space:]]*RUNNER_TOKEN=.+' "$env_file"; then
    warn "RUNNER_TOKEN is set in .env. For security, set it in your shell instead:"
    warn "  export RUNNER_TOKEN=...   (or prefix the command: RUNNER_TOKEN=... ./register.sh)"
  fi
}

# --- GitHub authentication ---------------------------------------------------
# RUNNER_TOKEN may hold EITHER a personal access token (PAT) or a short-lived
# registration/removal token. PATs carry a recognizable prefix; registration
# tokens do not, so we can tell them apart.

AUTH_MODE=""   # "gh" or "pat"; set by resolve_auth / the register flow

# True if the value looks like a GitHub PAT rather than a registration token.
looks_like_pat() {
  case "${1:-}" in
    ghp_*|github_pat_*|gho_*|ghu_*|ghs_*|ghr_*) return 0 ;;
    *) return 1 ;;
  esac
}

# Decide how to reach the GitHub API: a logged-in gh CLI, else RUNNER_TOKEN when
# it is a PAT. Sets AUTH_MODE. Returns non-zero if no API auth is available.
resolve_auth() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    AUTH_MODE="gh"
  elif [[ -n "${RUNNER_TOKEN:-}" ]] && looks_like_pat "${RUNNER_TOKEN}"; then
    AUTH_MODE="pat"
  else
    return 1
  fi
}

# api METHOD PATH — call the GitHub API with the resolved auth; prints the body.
api() {
  local method="$1" path="$2"
  if [[ "$AUTH_MODE" == "gh" ]]; then
    gh api -X "$method" -H "Accept: application/vnd.github+json" "$path"
  else
    curl -fsSL --proto '=https' --tlsv1.2 -X "$method" \
      -H "Authorization: Bearer ${RUNNER_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com${path}"
  fi
}

# Mint a fresh org runner registration token via the API. Prints the token.
# Requires AUTH_MODE to be set and the credential to carry the admin:org (or
# manage_runners:org) scope.
mint_registration_token() {
  local out
  out="$(api POST "/orgs/${GITHUB_ORG}/actions/runners/registration-token")" || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.token'
  else
    printf '%s\n' "$out" | sed -nE 's/.*"token": *"([^"]+)".*/\1/p' | sed -n '1p'
  fi
}

# --- platform ----------------------------------------------------------------

# Detect OS/arch and set the GitHub runner asset name plus friendly labels:
#   RUNNER_ASSET  e.g. osx-arm64
#   OS_LABEL      e.g. macOS
#   ARCH_LABEL    e.g. arm64
detect_platform() {
  local kernel machine
  kernel="$(uname -s)"
  machine="$(uname -m)"

  case "$kernel" in
    Darwin) PLATFORM_OS="osx";   OS_LABEL="macOS" ;;
    Linux)  PLATFORM_OS="linux"; OS_LABEL="Linux" ;;
    *) die "unsupported OS: $kernel (only macOS and Linux are supported)" ;;
  esac

  case "$machine" in
    x86_64|amd64)  PLATFORM_ARCH="x64";   ARCH_LABEL="x64" ;;
    arm64|aarch64) PLATFORM_ARCH="arm64"; ARCH_LABEL="arm64" ;;
    *) die "unsupported architecture: $machine (expected x86_64 or arm64)" ;;
  esac

  # shellcheck disable=SC2034
  RUNNER_ASSET="${PLATFORM_OS}-${PLATFORM_ARCH}"
}

# Compute the full label list: defaults plus any custom labels from .env.
runner_labels() {
  local defaults="self-hosted,${OS_LABEL},${ARCH_LABEL}"
  if [[ -n "${RUNNER_LABELS:-}" ]]; then
    printf '%s,%s' "$defaults" "$RUNNER_LABELS"
  else
    printf '%s' "$defaults"
  fi
}

# The name prefix for runners: RUNNER_NAME_PREFIX or this host's short name.
runner_prefix() {
  printf '%s' "${RUNNER_NAME_PREFIX:-$(hostname -s)}"
}

# --- process management -------------------------------------------------

# Where launch.sh records its own pid, so the recovery scripts can find it
# without inspecting process trees. See record_launch_sh_pid.
LAUNCH_PIDFILE="$CACHE_DIR/launch.pid"

# ppid of PID, and command line of PID. A pid can exit between the pgrep that
# listed it and the ps that inspects it; ps then exits non-zero, which errexit
# would turn into a dead caller — and these are called on exactly the process
# churn the recovery scripts exist to survive. Both print nothing for a pid that
# is already gone.
process_ppid()    { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ' || true; }
process_command() { ps -o command= -p "$1" 2>/dev/null || true; }

# Recursively send SIGNAL to a process and all its descendants. Needed
# because run.sh launches its children as plain background jobs (not via
# exec), so signalling the top pid alone would not reach them.
kill_tree() {
  local sig="$1" pid="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$sig" "$child"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# Record this process as the launch.sh supervising this repo's runners, and
# clear that record again. A supervisor is otherwise findable only through a
# live runner child of its own: it is started as "./launch.sh", so its command
# line names no path, and once its runners have all exited there is nothing left
# to find it by — while it is still up, still holding the terminal, and still
# about to be told it does not exist. Neither call is allowed to fail the
# caller: the record is an aid to recovery, never a precondition for running.
record_launch_sh_pid() {
  mkdir -p "$(dirname "$LAUNCH_PIDFILE")" 2>/dev/null || true
  printf '%s\n' "$$" > "$LAUNCH_PIDFILE" 2>/dev/null || true
  return 0
}

clear_launch_sh_pid() {
  local recorded
  recorded="$(head -n1 "$LAUNCH_PIDFILE" 2>/dev/null || true)"
  # Only ever withdraw our own record. A second launch.sh that started after us
  # owns the file now, and erasing its record would hide a live supervisor.
  [[ "$recorded" == "$$" ]] && rm -f "$LAUNCH_PIDFILE" 2>/dev/null
  return 0
}

# The recorded launch.sh pid, when there is still a launch.sh behind it. The
# record outlives the process that wrote it — a SIGKILLed launch.sh never gets
# to clear it — and the kernel hands the number out again, so neither the file
# nor liveness alone is evidence. Prints nothing when the record proves nothing.
recorded_launch_sh_pid() {
  local recorded
  recorded="$(head -n1 "$LAUNCH_PIDFILE" 2>/dev/null || true)"
  [[ "$recorded" =~ ^[1-9][0-9]*$ ]] || return 0
  kill -0 "$recorded" 2>/dev/null || return 0
  [[ "$(process_command "$recorded")" == *launch.sh* ]] || return 0
  printf '%s\n' "$recorded"
}

# True if a live launch.sh supervises this repo's runners — the question every
# caller that is about to kill a runner has to get right, because the wrong
# answer interrupts a running job.
runners_supervised() {
  [[ -n "$(repo_launch_sh_pids)" ]]
}

# PIDs of every live launch.sh supervising this repo's runners, one per line,
# each printed once: the pid launch.sh recorded for itself, plus the parent of
# every runner tree when that parent's command names launch.sh. The two sources
# answer the same question by independent means, and a supervisor missed by both
# is one whose runners get killed out from under it, so this reports the union
# rather than picking a winner.
repo_launch_sh_pids() {
  local pid seen=""
  for pid in $(recorded_launch_sh_pid) $(runner_supervisor_pids); do
    case " $seen " in
      *" $pid "*) continue ;;
    esac
    seen="$seen $pid"
    printf '%s\n' "$pid"
  done
}

# Parents of this repo's runner trees whose command names launch.sh. An orphan's
# parent is pid 1 instead, which is what tells the two apart.
runner_supervisor_pids() {
  local pid parent
  for pid in $(runner_pids); do
    parent="$(process_ppid "$pid")"
    [[ -n "$parent" && "$parent" -ne 1 ]] || continue
    [[ "$(process_command "$parent")" == *launch.sh* ]] || continue
    printf '%s\n' "$parent"
  done
}

# True when COMMAND is a runner's top-level run.sh, whatever path started it.
is_run_sh_command() {
  case "$1" in
    */run.sh|*/run.sh' '*) return 0 ;;
    *) return 1 ;;
  esac
}

# Every live process whose command line matches PATTERN, defaulting to every
# process under $RUNNERS_DIR. This is the single source of that pgrep pattern —
# every other function here reaches the process list through it, so no two of
# them can drift apart.
_runner_pgrep() {
  pgrep -f "${1:-$RUNNERS_DIR}" 2>/dev/null || true
}

# The top-level run.sh of every runner tree that PATTERN matches, each printed
# once.
#
# Whether run.sh's own command line names this repository is not this
# repository's decision to make. launch.sh starts it as
# `( cd "$d" && exec ./run.sh ) &`, and whether that reaches execve as
# "./run.sh" or as the absolute path is up to the shell: bash rewrites the path,
# zsh passes it through. A run.sh that names no path is invisible to any pattern
# match, yet it is the process that holds the tree together — it restarts
# run-helper.sh every time the helper exits, so a stop that cannot see it never
# converges, and a supervisor check that cannot see it reads a supervised fleet
# as orphaned and kills it mid-job.
#
# So find it two ways: by its own command line when the shell gave it one, and
# otherwise through its children. run.sh resolves its own directory and starts
# run-helper.sh by absolute path, so a helper carries $RUNNERS_DIR even when its
# parent carries nothing. The parent of a matched process, kept only when that
# parent is itself a run.sh, is the top of the tree under either shell.
runner_tree_roots() {
  local pattern="${1:-$RUNNERS_DIR}" pid parent root seen=""
  for pid in $(_runner_pgrep "$pattern"); do
    root=""
    if is_run_sh_command "$(process_command "$pid")"; then
      root="$pid"
    else
      parent="$(process_ppid "$pid")"
      [[ -n "$parent" && "$parent" -ne 1 ]] || continue
      is_run_sh_command "$(process_command "$parent")" && root="$parent"
    fi
    [[ -n "$root" ]] || continue
    case " $seen " in
      *" $root "*) continue ;;
    esac
    seen="$seen $root"
    printf '%s\n' "$root"
  done
}

# PIDs of every live top-level runner run.sh process.
runner_pids() {
  runner_tree_roots "$RUNNERS_DIR/runner-"
}

# Every live runner process matching PATTERN, defaulting to every process under
# $RUNNERS_DIR: run.sh, run-helper.sh, Runner.Listener, and Runner.Worker —
# broader than runner_pids, which reports only the top-level run.sh of each
# tree. The tree roots are folded in because a run.sh whose command line names
# no path is still a runner process, and a caller that swept the pattern alone
# would leave the one process that restarts everything it just killed. A caller
# passes a narrower pattern when it must not reach beyond the set it has already
# tested; the roots stay inside that pattern, since they are found through it.
runner_process_pids() {
  local pattern="${1:-$RUNNERS_DIR}" pid seen=""
  for pid in $(_runner_pgrep "$pattern") $(runner_tree_roots "$pattern"); do
    case " $seen " in
      *" $pid "*) continue ;;
    esac
    seen="$seen $pid"
    printf '%s\n' "$pid"
  done
}

# Stop every live runner process tree, escalating SIGINT -> SIGTERM ->
# SIGKILL (same as launch.sh's own cleanup). Used when no launch.sh remains
# to do it — e.g. it crashed or its terminal was closed, leaving orphaned
# runner processes with no supervisor to interrupt them.
stop_orphaned_runners() {
  local sig pid pids waited
  for sig in INT TERM KILL; do
    pids="$(runner_pids)"
    [[ -n "$pids" ]] || return 0
    for pid in $pids; do
      kill_tree "$sig" "$pid"
    done
    waited=0
    while [[ -n "$(runner_pids)" ]] && (( waited < 10 )); do
      sleep 1
      waited=$((waited + 1))
    done
  done
  [[ -z "$(runner_pids)" ]]
}

# Filters runner_process_pids down to the pids nuke_runner_processes may
# signal, dropping the caller and the caller's parent. Kept as its own
# function so that exclusion lives in exactly one place: the caller's own
# argv can contain the swept pattern (e.g. invoked from inside $RUNNERS_DIR),
# which would otherwise let the sweep match itself. PATTERN is passed through
# to runner_process_pids and defaults the same way.
_nuke_target_pids() {
  local exclude_self="$1" exclude_parent="$2" pattern="${3:-$RUNNERS_DIR}" pid
  for pid in $(runner_process_pids "$pattern"); do
    [[ "$pid" == "$exclude_self" || "$pid" == "$exclude_parent" ]] && continue
    printf '%s\n' "$pid"
  done
}

# Which of PIDS are still live runner processes under PATTERN, printed one per
# line. Reads liveness the same way the sweep chose its targets in the first
# place, so a pid that has exited, or that is left as a zombie until its parent
# reaps it, drops out here exactly as it drops out of a pattern match.
_nuke_surviving_pids() {
  local pids="$1" pattern="${2:-$RUNNERS_DIR}" pid live
  live=" $(runner_process_pids "$pattern" | tr '\n' ' ') "
  for pid in $pids; do
    case "$live" in
      *" $pid "*) printf '%s\n' "$pid" ;;
    esac
  done
}

# Stop every live process matching PATTERN, however it is rooted: a still
# running run.sh, an orphaned helper, or a listener/worker with no run.sh
# left above it. Escalates SIGINT -> SIGTERM -> SIGKILL like
# stop_orphaned_runners, but sweeps runner_process_pids' broader set (not
# just runner_pids' top-level run.sh) and calls kill_tree on every root, so
# a job's own descendants are reached even when their command line doesn't
# name $RUNNERS_DIR.
#
# PATTERN defaults to $RUNNERS_DIR, which sweeps the whole runners tree. This
# kills without prompting or naming what it hit, so a caller that has already
# tested a narrower set should pass that narrower pattern rather than widen its
# own reach; only an operator-facing command that lists every pid first has any
# business using the default.
#
# The set to kill is chosen once, up front, and every later step asks only
# which of those pids are left. Matching the pattern again on each poll cannot
# say when the sweep is done, because a match found on a later poll can be one
# the sweep itself created: every `$(...)` here forks a subshell that carries
# the caller's argv until it execs, so a caller whose own argv embeds the
# pattern hands that pattern to each of its own forks, and Linux pgrep -f
# reports them (macOS pgrep -f hides pgrep's own ancestors, so it does not).
# The sweep would then chase processes it makes faster than it can kill them,
# escalate all the way to SIGKILL against pids that already exited, and report
# failure with nothing left alive. Anything a live target spawns mid-sweep is
# still reached, since kill_tree walks each target's children at every stage.
nuke_runner_processes() {
  local pattern="${1:-$RUNNERS_DIR}" sig pid pids waited self parent targets
  self="$$"
  parent="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d ' ')"
  targets="$(_nuke_target_pids "$self" "$parent" "$pattern")"

  for sig in INT TERM KILL; do
    pids="$(_nuke_surviving_pids "$targets" "$pattern")"
    [[ -n "$pids" ]] || return 0
    for pid in $pids; do
      kill_tree "$sig" "$pid"
    done
    waited=0
    while [[ -n "$(_nuke_surviving_pids "$targets" "$pattern")" ]] && (( waited < 10 )); do
      sleep 1
      waited=$((waited + 1))
    done
  done

  [[ -z "$(_nuke_surviving_pids "$targets" "$pattern")" ]]
}

# Ensure no runner process is left alive before mutating local runner state
# (credentials, .runner, etc.):
#   - if launch.sh is actively supervising them, refuse — let it own them,
#     since killing them out from under it could interrupt a running job.
#   - if they're orphaned (launch.sh is gone) and dry_run is true, just
#     report that they would be stopped.
#   - if they're orphaned and dry_run is false, stop them.
# Dies with an actionable message if runners are still alive afterwards.
ensure_runners_stopped() {
  # Every step reads this one pattern through runner_process_pids, so the set
  # this function tests, the set it sweeps and the set it finally refuses on are
  # the same set by construction. Widening any one of them alone would let it
  # kill a process it never claimed to be looking at.
  local dry_run="$1" gate="$RUNNERS_DIR/runner-" supervisors
  [[ -n "$(runner_process_pids "$gate")" ]] || return 0

  supervisors="$(repo_launch_sh_pids | tr '\n' ' ')"
  if [[ -n "${supervisors// /}" ]]; then
    die "runners appear to be running under launch.sh: pid ${supervisors% }. Stop it (Ctrl+C/Ctrl+D) first, or run ./nuke-runners.sh to stop it and every runner."
  fi

  if [[ "$dry_run" == "true" ]]; then
    info "found orphaned runner processes (no launch.sh supervising them) — would stop them"
    return 0
  fi

  warn "found orphaned runner processes (no launch.sh supervising them) — stopping them"
  stop_orphaned_runners || true

  # stop_orphaned_runners only reaches trees still rooted at a top-level run.sh.
  # A Runner.Listener or Runner.Worker whose run.sh already exited matches the
  # gate but gives stop_orphaned_runners no root to signal, so fall through to
  # the rootless sweep rather than give up: the promise here is that no runner
  # process is left alive. The sweep is held to the gate pattern, which every
  # real runner process is reachable through — it carries runners/runner-N/ in
  # its argv, or it is the run.sh above one that does — while a bystander merely
  # working under $RUNNERS_DIR is never touched by a kill this function neither
  # prompts for nor records.
  if [[ -n "$(runner_process_pids "$gate")" ]]; then
    warn "runner processes remain with no run.sh above them — sweeping every process matching $gate"
    nuke_runner_processes "$gate" || true
  fi

  [[ -n "$(runner_process_pids "$gate")" ]] \
    && die "could not stop orphaned runner processes; run ./nuke-runners.sh, then retry."
  return 0
}
