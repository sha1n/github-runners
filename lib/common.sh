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

# Validate the variables register.sh needs.
require_vars() {
  [[ -n "${GITHUB_ORG:-}" ]]   || die "GITHUB_ORG is not set (copy .env.example to .env)"
  [[ -n "${RUNNER_TOKEN:-}" ]] || die "RUNNER_TOKEN is not set (copy .env.example to .env)"
  [[ "${RUNNER_COUNT:-}" =~ ^[1-9][0-9]*$ ]] \
    || die "RUNNER_COUNT must be a positive integer (got '${RUNNER_COUNT:-}')"
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
