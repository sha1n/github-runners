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

# True if this machine's launch.sh is actively supervising the runners.
launch_sh_running() {
  pgrep -f "$REPO_ROOT/launch.sh" >/dev/null 2>&1
}

# PIDs of every live top-level runner run.sh process.
runner_pids() {
  pgrep -f "$RUNNERS_DIR/runner-.*/run\.sh" 2>/dev/null || true
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

# Ensure no runner process is left alive before mutating local runner state
# (credentials, .runner, etc.):
#   - if launch.sh is actively supervising them, refuse — let it own them,
#     since killing them out from under it could interrupt a running job.
#   - if they're orphaned (launch.sh is gone) and dry_run is true, just
#     report that they would be stopped.
#   - if they're orphaned and dry_run is false, stop them.
# Dies with an actionable message if runners are still alive afterwards.
ensure_runners_stopped() {
  local dry_run="$1"
  pgrep -f "$RUNNERS_DIR/runner-" >/dev/null 2>&1 || return 0

  if launch_sh_running; then
    die "runners appear to be running under launch.sh. Stop it (Ctrl+C/Ctrl+D) first."
  fi

  if [[ "$dry_run" == "true" ]]; then
    info "found orphaned runner processes (no launch.sh supervising them) — would stop them"
    return 0
  fi

  warn "found orphaned runner processes (no launch.sh supervising them) — stopping them"
  stop_orphaned_runners
  pgrep -f "$RUNNERS_DIR/runner-" >/dev/null 2>&1 \
    && die "could not stop orphaned runner processes; stop them manually and retry."
  return 0
}
