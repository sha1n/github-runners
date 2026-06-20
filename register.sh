#!/usr/bin/env bash
# First-time setup: download the GitHub Actions runner once, then register
# RUNNER_COUNT runners against the configured organization. The credential
# (RUNNER_TOKEN from the shell, a PAT or a registration token, or a logged-in
# gh CLI) is resolved at run time — see resolve_registration_token.
#
# Idempotent: re-running only fills in missing/unconfigured runners. There is
# deliberately no version-update path — live runners keep themselves current
# via GitHub's auto-update.
#
# Usage:
#   ./register.sh            register runners using .env
#   ./register.sh --dry-run  print the planned actions without contacting GitHub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./register.sh [--dry-run]

  --dry-run   Show what would be downloaded and registered, without
              contacting GitHub or writing anything.
  -h, --help  Show this help.

Configuration is read from .env (see .env.example).
EOF
}

# Resolve the actions/runner version to download. "latest" (the default)
# queries the GitHub API for the newest release; otherwise the pinned version
# is used verbatim. Sets RUNNER_VERSION (without a leading "v").
resolve_version() {
  local v="${RUNNER_DOWNLOAD_VERSION:-latest}"
  if [[ -z "$v" || "$v" == "latest" ]]; then
    info "Resolving latest actions/runner release..."
    # Capture the response in full first: piping curl straight into an
    # early-exiting stage (grep -m1/head) makes curl fail with SIGPIPE, which
    # `set -o pipefail` turns into a silent script exit.
    local json
    json="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)" \
      || die "could not reach the GitHub API to resolve the latest runner version"
    v="$(printf '%s\n' "$json" \
         | sed -nE 's/.*"tag_name": *"v?([^"]+)".*/\1/p' \
         | sed -n '1p')"
    [[ -n "$v" ]] || die "could not parse the latest runner version from GitHub"
  fi
  RUNNER_VERSION="${v#v}"
}

# Fetch the SHA-256 GitHub publishes for the given release asset, parsed from
# the release notes ("<!-- BEGIN SHA <asset> -->HASH"). Prints the hash.
fetch_published_sha256() {
  local version="$1" asset="$2" json
  json="$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${version}")" \
    || return 1
  # grep with no -m1 and sed without an early `q` both read to EOF, so no
  # upstream SIGPIPE under `set -o pipefail`.
  printf '%s\n' "$json" \
    | grep -oE "BEGIN SHA ${asset} -->[0-9a-f]{64}" \
    | sed -nE 's/.*-->([0-9a-f]{64})/\1/p' \
    | sed -n '1p'
}

# Resolve a runner registration token into REG_TOKEN. RUNNER_TOKEN (from the
# shell) may be a PAT — which we exchange for a registration token via the API —
# or a registration token, used as-is. With no RUNNER_TOKEN we mint one through a
# logged-in gh CLI.
resolve_registration_token() {
  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    if looks_like_pat "$RUNNER_TOKEN"; then
      info "RUNNER_TOKEN is a PAT — minting a registration token..."
      AUTH_MODE="pat"
      REG_TOKEN="$(mint_registration_token)" \
        || die "could not mint a registration token. Ensure the PAT has the admin:org (or manage_runners:org) scope."
    else
      info "Using the provided RUNNER_TOKEN as a registration token."
      REG_TOKEN="$RUNNER_TOKEN"
    fi
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    info "Minting a registration token via the gh CLI..."
    AUTH_MODE="gh"
    REG_TOKEN="$(mint_registration_token)" \
      || die "could not mint a registration token via gh. Ensure the admin:org scope:
    gh auth refresh -h github.com -s admin:org"
  else
    die "no credential available. Set RUNNER_TOKEN in your shell (a PAT or a
  registration token), or log in with 'gh auth login'."
  fi
  [[ -n "${REG_TOKEN:-}" ]] || die "registration token resolution produced an empty token"
}

# Compute the SHA-256 of a file, using whichever tool is available.
sha256_of() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    die "no sha256 tool found (need shasum or sha256sum)"
  fi
}

# Download the runner tarball into the cache (once) and verify its checksum
# against the hash GitHub publishes for the release. Sets TARBALL.
download_runner() {
  mkdir -p "$CACHE_DIR"
  local file="actions-runner-${RUNNER_ASSET}-${RUNNER_VERSION}.tar.gz"
  local url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${file}"
  TARBALL="$CACHE_DIR/$file"

  if [[ -f "$TARBALL" ]]; then
    info "Using cached tarball: $TARBALL"
  else
    info "Downloading $url"
    curl -fL --proto '=https' --tlsv1.2 -o "$TARBALL.tmp" "$url" \
      || { rm -f "$TARBALL.tmp"; die "download failed: $url"; }
    mv "$TARBALL.tmp" "$TARBALL"
  fi

  local expected actual
  expected="$(fetch_published_sha256 "$RUNNER_VERSION" "$RUNNER_ASSET")" \
    || die "could not fetch the published checksum for $RUNNER_ASSET $RUNNER_VERSION"
  [[ -n "$expected" ]] \
    || die "GitHub did not publish a checksum for $RUNNER_ASSET $RUNNER_VERSION"
  actual="$(sha256_of "$TARBALL")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$TARBALL"
    die "checksum mismatch for $file
  expected: $expected
  actual:   $actual"
  fi
  info "Checksum verified."
}

# Write the runner's .env so every job runs with an isolated global git config.
# actions/checkout records `safe.directory` via `git config --global`, and its
# post-job cleanup step is skipped whenever a job is killed (e.g. launch.sh's
# SIGKILL escalation) — left unchecked those entries pile up in the operator's
# real ~/.gitconfig. Pointing GIT_CONFIG_GLOBAL at a throwaway file inside the
# runner's own dir keeps them out of it. git creates the file on first write, so
# there is nothing to pre-generate and nothing is copied from ~/.gitconfig. The
# file is per-runner (not shared) so the concurrent `git config` writes that
# happen when launch.sh starts every runner at once cannot race each other.
provision_runner_env() {
  local dir="$1" env_file="$1/.env"
  # Gated by ISOLATE_GIT_CONFIG in the repo-root .env; enabled unless set false.
  # Lowercase first (Bash 3.2 has no ${var,,}) so "False"/"Off" also disable it.
  local toggle
  toggle="$(printf '%s' "${ISOLATE_GIT_CONFIG:-true}" | tr '[:upper:]' '[:lower:]')"
  case "$toggle" in
    false|no|0|off) return 0 ;;
  esac
  local line="GIT_CONFIG_GLOBAL=$dir/.gitconfig-ci"
  if [[ -f "$env_file" ]] && grep -qxF "$line" "$env_file"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$env_file"
  info "Isolated global git config for $(basename "$dir") via $env_file"
}

# Extract (if needed) and register each runner.
configure_runners() {
  local labels prefix
  labels="$(runner_labels)"
  prefix="$(runner_prefix)"
  mkdir -p "$RUNNERS_DIR"

  local i dir name
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    dir="$RUNNERS_DIR/runner-$i"
    name="${prefix}-$i"
    mkdir -p "$dir"

    if [[ ! -x "$dir/config.sh" ]]; then
      info "Extracting runner into $dir"
      tar -xzf "$TARBALL" -C "$dir"
    fi

    provision_runner_env "$dir"

    if [[ -f "$dir/.runner" ]]; then
      info "runner-$i already configured (${name}); skipping"
      continue
    fi

    info "Registering runner-$i as ${name}"
    (
      cd "$dir"
      ./config.sh --unattended \
        --url "https://github.com/${GITHUB_ORG}" \
        --token "$REG_TOKEN" \
        --name "$name" \
        --labels "$labels" \
        --work "_work" \
        --replace
    )
  done
}

print_plan() {
  local prefix labels i
  prefix="$(runner_prefix)"
  labels="$(runner_labels)"
  cat <<EOF
Planned actions (dry run — nothing downloaded or registered):

  Organization : https://github.com/${GITHUB_ORG}
  Platform     : ${OS_LABEL}/${ARCH_LABEL}  (asset: ${RUNNER_ASSET})
  Download ver : ${RUNNER_DOWNLOAD_VERSION:-latest}
  Runner count : ${RUNNER_COUNT}
  Labels       : ${labels}
  Runners:
EOF
  for ((i = 1; i <= RUNNER_COUNT; i++)); do
    printf '    - %-20s %s\n' "${prefix}-$i" "${RUNNERS_DIR}/runner-$i"
  done
}

main() {
  local dry_run=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  load_env
  warn_if_secret_in_env
  require_vars
  detect_platform

  if $dry_run; then
    print_plan
    exit 0
  fi

  resolve_registration_token
  resolve_version
  download_runner
  configure_runners

  info "Done. ${RUNNER_COUNT} runner(s) registered. Run ./launch.sh to start them."
}

main "$@"
