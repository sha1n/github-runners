#!/usr/bin/env bash
# Mock supervisor for the supervisor-detection tests. Named launch.sh (and only
# ever invoked by that name, never a wrapped or renamed copy) so its own `ps -o
# command=` output carries the substring the helpers look for.
#
# Takes the runners to start from $MOCK_RUNNERS, one path per line, rather than
# from argv. The real launch.sh globs for its runners, so no runner path ever
# reaches its command line; a fixture that put one there would itself be matched
# by every pattern that hunts for a runner process.
#
# Starts each runner through env, from inside the runner directory. The real
# launch.sh writes `exec ./run.sh`, and a shell that rewrites the command path
# to an absolute one before it calls execve (bash does, zsh does not) turns that
# into an argv naming the runner directory. Going through env keeps the argv
# path-less whatever the shell does, which is the harder shape the helpers have
# to handle: run.sh's own command line then ties it to no fleet at all, and only
# its place in the process tree says where it belongs. The runner is still this
# process's direct child, exactly as under the real launch.sh.
set -uo pipefail
children=()
while IFS= read -r runner; do
  [[ -n "$runner" ]] || continue
  ( cd "$(dirname "$runner")" && exec env "./$(basename "$runner")" ) &
  children+=("$!")
done <<< "${MOCK_RUNNERS:-}"
# Stay alive even with no runner left to wait for, the way the real launch.sh
# blocks on stdin: a supervisor whose runners have all exited is a state the
# helpers still have to find.
sleep 300 &
children+=("$!")
trap 'kill "${children[@]}" 2>/dev/null; exit 0' INT TERM
wait
