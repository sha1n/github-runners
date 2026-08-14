#!/usr/bin/env bash
# Spawns a short-lived process every fraction of a second whose command line
# embeds $CHURN_TOKEN, while its own command line embeds nothing that a sweep
# matches. That is the shape of any process that only mentions $RUNNERS_DIR
# instead of being a runner: an operator tailing a diagnostic log, an editor,
# and — the case this fixture exists for — the command-substitution subshells a
# sweep forks to run pgrep, which inherit their caller's argv until they exec.
#
# `exit 0` keeps the token in the child's command line: bash replaces itself
# with the last command of a -c script when that command is the only one, and
# the token would go with it.
set -u
trap 'exit 0' INT TERM

while :; do
  bash -c 'sleep 0.3; exit 0' "$CHURN_TOKEN" &
  sleep 0.1
done
