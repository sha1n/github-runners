#!/usr/bin/env bash
# Tests for launch.sh's toolchain-env scrubbing: the runner inherits the full
# environment of the shell that started launch.sh, so a shell with mise active
# exports GOROOT and every runner leaks it into every CI job, where an
# inherited GOROOT makes jobs run the wrong Go compile tools.
#
# scrub_toolchain_env must unset GOROOT, GOBIN, and GOTOOLCHAIN — variable and
# export both — and must not touch anything else.
#
# Sourcing launch.sh here is what the source guard at its foot is for; nothing
# in this file may call a helper that acts on $RUNNERS_DIR, which sourcing
# points back at the real fleet.
#
# Usage: ./tests/test_launch_env.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_UNDER_TEST="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../launch.sh
source "$REPO_ROOT_UNDER_TEST/launch.sh"

FAILURES=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

test_scrub_unsets_the_toolchain_vars() {
  export GOROOT=/sentinel/goroot
  export GOBIN=/sentinel/gobin
  export GOTOOLCHAIN=sentinel-toolchain

  # Sourcing launch.sh enabled `set -e`, and only a failure tested in a
  # condition escapes it — the `if !` guard is what lets a missing function
  # fail with 127 and record a failure instead of killing the suite.
  if ! scrub_toolchain_env; then
    fail "scrub_toolchain_env runs and returns 0"
    unset GOROOT GOBIN GOTOOLCHAIN
    return
  fi
  pass "scrub_toolchain_env runs and returns 0"

  if [[ -z "${GOROOT+x}" ]]; then
    pass "GOROOT is unset after scrub"
  else
    fail "GOROOT is unset after scrub"
    unset GOROOT
  fi
  if [[ -z "${GOBIN+x}" ]]; then
    pass "GOBIN is unset after scrub"
  else
    fail "GOBIN is unset after scrub"
    unset GOBIN
  fi
  if [[ -z "${GOTOOLCHAIN+x}" ]]; then
    pass "GOTOOLCHAIN is unset after scrub"
  else
    fail "GOTOOLCHAIN is unset after scrub"
    unset GOTOOLCHAIN
  fi
}

test_scrub_removes_the_vars_from_a_child_environment() {
  export GOROOT=/sentinel/goroot
  export GOBIN=/sentinel/gobin
  export GOTOOLCHAIN=sentinel-toolchain

  if ! scrub_toolchain_env; then
    fail "a child process sees no GOROOT/GOBIN/GOTOOLCHAIN after scrub"
    unset GOROOT GOBIN GOTOOLCHAIN
    return
  fi

  local leaked
  leaked="$(env | grep -E '^(GOROOT|GOBIN|GOTOOLCHAIN)=' || true)"
  if [[ -z "$leaked" ]]; then
    pass "a child process sees no GOROOT/GOBIN/GOTOOLCHAIN after scrub"
  else
    fail "a child process sees no GOROOT/GOBIN/GOTOOLCHAIN after scrub"
    unset GOROOT GOBIN GOTOOLCHAIN
  fi
}

test_scrub_leaves_unrelated_vars_alone() {
  export SCRUB_TEST_KEEP=kept

  if ! scrub_toolchain_env; then
    fail "an unrelated exported variable survives the scrub"
    unset SCRUB_TEST_KEEP
    return
  fi

  if [[ "${SCRUB_TEST_KEEP:-}" == "kept" ]]; then
    pass "an unrelated exported variable survives the scrub"
  else
    fail "an unrelated exported variable survives the scrub"
  fi

  local child_value
  child_value="$(env | grep '^SCRUB_TEST_KEEP=' || true)"
  if [[ "$child_value" == "SCRUB_TEST_KEEP=kept" ]]; then
    pass "an unrelated exported variable is still exported to a child"
  else
    fail "an unrelated exported variable is still exported to a child"
  fi
  unset SCRUB_TEST_KEEP
}

test_scrub_unsets_the_toolchain_vars
test_scrub_removes_the_vars_from_a_child_environment
test_scrub_leaves_unrelated_vars_alone

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\nAll tests passed.\n'
  exit 0
else
  printf '\n%d test(s) failed.\n' "$FAILURES"
  exit 1
fi
