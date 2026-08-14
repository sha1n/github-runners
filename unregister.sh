#!/usr/bin/env bash
# Deregister all of this machine's runners from the GitHub organization and
# clean up their local configuration. The counterpart to register.sh.
#
# Two independent halves, so it copes with inconsistent state (a runner deleted
# on GitHub but still present locally, or vice versa):
#   1. GitHub side: delete every org runner whose name matches this machine's
#      prefix, via the REST API.
#   2. Local side:  run `config.sh remove --local` in each runner directory to
#      drop its .runner/.credentials (binaries are kept unless --purge).
#
# Usage:
#   ./unregister.sh            confirm, then deregister + clean locally
#   ./unregister.sh --dry-run  show what would be removed, contact nothing
#   ./unregister.sh --yes      skip the confirmation prompt
#   ./unregister.sh --purge    also delete the runner directories entirely
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./unregister.sh [--dry-run] [--yes] [--purge]

  --dry-run   Show which GitHub runners and local directories would be removed,
              without contacting GitHub or deleting anything.
  --yes       Skip the confirmation prompt (for automation).
  --purge     Also delete each runner directory (runners/runner-N) entirely.
              By default the extracted binaries are kept for fast re-register.
  -h, --help  Show this help.

Authentication (needs the admin:org or fine-grained manage_runners:org scope):
  - Uses the gh CLI if it is installed and logged in (recommended).
  - Otherwise uses RUNNER_TOKEN from your shell, if it is a PAT.

Configuration is read from .env (only GITHUB_ORG is required here). The
credential comes from your shell, never .env.
EOF
}

# Authentication (resolve_auth / api) is shared from lib/common.sh. Deleting
# runners via the API needs a PAT or a logged-in gh CLI — a bare registration
# token cannot drive it.

# Print "id<TAB>name" for every runner registered to the org, across all pages.
list_org_runners() {
  if [[ "$AUTH_MODE" == "gh" ]]; then
    gh api --paginate "/orgs/${GITHUB_ORG}/actions/runners" \
      --jq '.runners[] | "\(.id)\t\(.name)"'
  else
    local page=1 chunk n
    while :; do
      chunk="$(api GET "/orgs/${GITHUB_ORG}/actions/runners?per_page=100&page=${page}")" || return 1
      n="$(printf '%s' "$chunk" | jq '.runners | length')"
      [[ "$n" -eq 0 ]] && break
      printf '%s' "$chunk" | jq -r '.runners[] | "\(.id)\t\(.name)"'
      [[ "$n" -lt 100 ]] && break
      page=$((page + 1))
    done
  fi
}

# --- local cleanup -----------------------------------------------------------

# Remove the local configuration of one runner directory. Uses config.sh's own
# --local removal when possible, falling back to deleting the config files.
clean_local() {
  local d="$1"
  if [[ -x "$d/config.sh" && ( -f "$d/.runner" || -f "$d/.credentials" ) ]]; then
    if ! ( cd "$d" && ./config.sh remove --local ) >/dev/null 2>&1; then
      warn "config.sh remove --local failed for $(basename "$d"); deleting config files directly"
      rm -f "$d/.runner" "$d/.credentials" "$d/.credentials_rsaparams"
    fi
  else
    rm -f "$d/.runner" "$d/.credentials" "$d/.credentials_rsaparams"
  fi
}

# --- main --------------------------------------------------------------------

main() {
  local dry_run=false assume_yes=false purge=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --yes|-y)  assume_yes=true ;;
      --purge)   purge=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  load_env
  [[ -n "${GITHUB_ORG:-}" ]] || die "GITHUB_ORG is not set (copy .env.example to .env)"

  # Don't deregister runners that are still working. A supervised fleet is
  # refused so a running job is never cut short; orphans, which no launch.sh
  # can be asked to stop, are cleared here instead.
  ensure_runners_stopped "$dry_run"

  resolve_auth || die "no GitHub API auth available.
  Log in with 'gh auth login' (and add scope: gh auth refresh -h github.com -s admin:org),
  or set RUNNER_TOKEN to a PAT (with the admin:org scope) in your shell."
  case "$AUTH_MODE" in
    gh)  info "Authenticating via the gh CLI." ;;
    pat) info "Authenticating via RUNNER_TOKEN (PAT)." ;;
  esac

  local prefix
  prefix="$(runner_prefix)"

  # Select org runners belonging to this machine: name == "<prefix>-<digits>".
  local runners_raw matches="" id name suffix
  runners_raw="$(list_org_runners)" \
    || die "could not list org runners. Ensure the token has the admin:org scope:
    gh auth refresh -h github.com -s admin:org   (or set a scoped GITHUB_PAT in .env)"
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" ]] || continue
    case "$name" in
      "$prefix"-*) suffix="${name#"$prefix"-}" ;;
      *) continue ;;
    esac
    [[ "$suffix" =~ ^[0-9]+$ ]] || continue
    matches+="${id}	${name}"$'\n'
  done <<< "$runners_raw"

  # Local runner directories.
  local local_dirs=() d
  if [[ -d "$RUNNERS_DIR" ]]; then
    for d in "$RUNNERS_DIR"/runner-*; do
      [[ -d "$d" ]] && local_dirs+=("$d")
    done
  fi

  # Plan.
  local n_remote
  n_remote="$(printf '%s' "$matches" | grep -c . || true)"
  info "Organization : https://github.com/${GITHUB_ORG}"
  info "Runner prefix: ${prefix}"
  echo
  echo "GitHub runners to delete (${n_remote}):"
  if [[ "$n_remote" -gt 0 ]]; then
    while IFS=$'\t' read -r id name; do
      [[ -n "$id" ]] && printf '    - %-24s (id %s)\n' "$name" "$id"
    done <<< "$matches"
  else
    echo "    (none matched)"
  fi
  echo "Local runner directories to clean (${#local_dirs[@]})$($purge && echo ' and DELETE'):"
  if [[ ${#local_dirs[@]} -gt 0 ]]; then
    for d in "${local_dirs[@]}"; do printf '    - %s\n' "$d"; done
  else
    echo "    (none)"
  fi
  echo

  if [[ "$n_remote" -eq 0 && ${#local_dirs[@]} -eq 0 ]]; then
    info "Nothing to unregister."
    exit 0
  fi

  if $dry_run; then
    info "Dry run — nothing was deleted."
    exit 0
  fi

  if ! $assume_yes; then
    printf 'Proceed with deletion? [y/N] '
    local reply=""
    read -r reply || true
    case "$reply" in
      y|Y|yes|Yes) ;;
      *) die "aborted." ;;
    esac
  fi

  # Delete on GitHub.
  if [[ "$n_remote" -gt 0 ]]; then
    while IFS=$'\t' read -r id name; do
      [[ -n "$id" ]] || continue
      info "Deleting GitHub runner ${name} (id ${id})"
      api DELETE "/orgs/${GITHUB_ORG}/actions/runners/${id}" >/dev/null \
        || warn "failed to delete ${name} (id ${id})"
    done <<< "$matches"
  fi

  # Clean up locally.
  for d in "${local_dirs[@]}"; do
    info "Cleaning $(basename "$d")"
    clean_local "$d"
    if $purge; then
      rm -rf "$d"
    fi
  done

  info "Done. Runners unregistered."
}

main "$@"
