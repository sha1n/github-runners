#!/usr/bin/env bash
# First-time setup: download the GitHub Actions runner once, then register
# RUNNER_COUNT runners against the configured organization using one token.
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

    if [[ -f "$dir/.runner" ]]; then
      info "runner-$i already configured (${name}); skipping"
      continue
    fi

    info "Registering runner-$i as ${name}"
    (
      cd "$dir"
      ./config.sh --unattended \
        --url "https://github.com/${GITHUB_ORG}" \
        --token "$RUNNER_TOKEN" \
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
  require_vars
  detect_platform

  if $dry_run; then
    print_plan
    exit 0
  fi

  resolve_version
  download_runner
  configure_runners

  info "Done. ${RUNNER_COUNT} runner(s) registered. Run ./launch.sh to start them."
}

main "$@"
