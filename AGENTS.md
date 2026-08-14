# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

A small Bash toolkit for running a fleet of **GitHub Actions self-hosted
runners** as native processes on one machine, registered at the
**organization** level. Five entry points plus a shared library:

- `register.sh` — first-time setup: download the runner once, register
  `RUNNER_COUNT` runners. Idempotent; no version-update path (runners
  auto-update at runtime). Also provisions each `runners/runner-N/.env` with
  `GIT_CONFIG_GLOBAL` (unless `ISOLATE_GIT_CONFIG=false`) so the
  `safe.directory` entries `actions/checkout` writes via `git config --global`
  stay out of the operator's `~/.gitconfig`.
- `launch.sh` — start all registered runners; stop them cleanly on `Ctrl+C`
  (SIGINT), `Ctrl+D` (EOF), `Ctrl+\` (SIGQUIT), a closed terminal (SIGHUP), or
  any error exit (the `EXIT` trap). Uses job control so each runner leads its
  own process group, then signals the group (SIGINT → SIGTERM → SIGKILL).
  Records its own pid in `.cache/launch.pid` (`record_launch_sh_pid`) and
  withdraws it in `cleanup`, because a supervisor whose runners have all exited
  has no child left to be found through and its own command line names no path.
  Sources are guarded at the foot of the file so tests can source it for its
  signal handling without starting the fleet.
- `unregister.sh` — delete this machine's runners from the org via the API and
  clean local config. `--dry-run`, `--yes`, `--purge`.
- `fix-zombie-runners.sh` — detect and recover runners stuck with a stale
  GitHub broker session (a runner process killed non-gracefully — crash,
  SIGKILL, host sleep — never closes its session, so a fresh `run.sh` gets
  `TaskAgentSessionConflictException` / "A session for this runner already
  exists" forever). Clears the local files that block re-registration
  (`.runner`, `.credentials`, `.credentials_rsaparams`, `.runner_migrated` —
  the last one is a broker-migration marker that makes `config.sh` refuse to
  reconfigure even after the others are gone) and delegates to `register.sh`
  to redo the registration with `--replace`, which clears the stuck session
  on GitHub's side too. `--dry-run` shows which runners are stuck without
  touching anything. Refuses to run while `launch.sh` is actively
  supervising the runners, but if runner processes are alive and orphaned
  (`launch.sh` itself died — crash, closed terminal — without cleaning up),
  stops them itself first via `ensure_runners_stopped` rather than telling
  the operator to stop a process that no longer exists.
- `nuke-runners.sh` — last-resort recovery for orphaned runner processes left
  behind when no signal trap could run (the terminal holding `launch.sh` was
  killed with `SIGKILL`, or the machine lost power): each surviving
  `Runner.Listener` keeps its GitHub broker session alive, so a fresh
  `launch.sh` hits the same session conflict as a zombie runner, but waiting
  can't clear it since the session is live, not stale. Unlike
  `fix-zombie-runners.sh`, it never defers to a running `launch.sh` — that
  refusal is exactly what leaves the operator stuck — so it stops any
  `launch.sh` it finds first, then sweeps every process under
  `$RUNNERS_DIR`. `--dry-run`, `--yes`/`-y`. Contacts no network, needs no
  credential, changes no file on disk.
- `lib/common.sh` — shared helpers, sourced by all five. Logging
  (`info`/`warn`/`die`), `load_env`, `require_vars`, platform detection,
  runner naming, GitHub auth (`resolve_auth`, `api`, `looks_like_pat`,
  `mint_registration_token`), and process management (`kill_tree`,
  `process_ppid`, `process_command`, `is_run_sh_command`, `runner_tree_roots`,
  `runner_pids`, `runner_process_pids`, `runners_supervised`,
  `runner_supervisor_pids`, `repo_launch_sh_pids`, `record_launch_sh_pid`,
  `clear_launch_sh_pid`, `recorded_launch_sh_pid`, `stop_orphaned_runners`,
  `nuke_runner_processes`, `ensure_runners_stopped`).

  **Finding a runner process is not a pattern match.** `launch.sh` starts a
  runner as `( cd "$d" && exec ./run.sh ) &`, and whether that reaches `execve`
  as `./run.sh` or as the absolute path is the shell's choice, not this repo's:
  Bash rewrites the path, zsh passes it through. A `run.sh` whose argv names no
  path is invisible to `pgrep -f`, and it is the process that restarts
  `run-helper.sh` — so a stop that misses it never converges and a supervisor
  check that misses it reads a live fleet as orphaned and kills it mid-job.
  `runner_tree_roots` therefore finds a `run.sh` by its own argv *or* through a
  child that does carry the path, and every other helper reads the process list
  through it. Keep it that way; do not reintroduce a bare `pgrep -f` on a
  `run.sh` path.

## Authentication & secrets — IMPORTANT

The credential is **never stored in `.env`**. `.env` holds non-secret config
only (`GITHUB_ORG`, `RUNNER_COUNT`, prefix, labels, download version,
`ISOLATE_GIT_CONFIG`). The secret comes from the **shell environment** so it is
not persisted to disk.

Two sources, resolved at run time:

1. **`gh` CLI** — if installed and logged in (`gh auth status` succeeds).
2. **`RUNNER_TOKEN`** env var — a single parameter that holds **either**:
   - a **PAT** (`ghp_`/`github_pat_`/`gho_`/`ghu_`/`ghs_`/`ghr_` prefix), or
   - a **registration token** (no such prefix).

   `looks_like_pat` distinguishes them by prefix. A PAT is exchanged for a
   registration token via `POST /orgs/{org}/actions/runners/registration-token`
   (`mint_registration_token`); a registration token is used directly with
   `config.sh`.

Resolution order differs by script:
- `register.sh`: explicit `RUNNER_TOKEN` first, else `gh`. Accepts PAT or
  registration token. Warns (via `warn_if_secret_in_env`) if `RUNNER_TOKEN` is
  found in `.env`.
- `unregister.sh`: `gh` first, else `RUNNER_TOKEN` **only if it is a PAT**
  (API deletion cannot be driven by a bare registration token).

Required scope: `admin:org` (classic) or `manage_runners:org` (fine-grained).

When editing auth: keep secrets out of `.env` and out of logs; route all API
calls through `api()`; surface the `gh auth refresh -h github.com -s admin:org`
hint on a 403/scope failure.

## Conventions

- Target **Bash 3.2** (macOS system bash): no associative arrays, no `mapfile`,
  no `wait -n`.
- Every script starts with `set -euo pipefail`. Beware the pipefail + SIGPIPE
  trap: capture `curl` output into a variable first, then parse it (piping
  `curl` straight into an early-exiting stage like `grep -m1`/`head` makes curl
  fail and silently aborts the script). See `resolve_version` in `register.sh`.
- Reuse `lib/common.sh` rather than duplicating helpers across scripts.
- Match the existing style: `info`/`warn`/`die` for output, `--dry-run` and
  `--help` on user-facing scripts, idempotent operations where possible.

## Repo layout & gitignore

- Runtime state is gitignored and untracked: `.env`, `runners/`, `.cache/`
  (the downloaded runner tarball and `launch.pid`).
  Never assume `runners/` is empty — it holds real registered runners
  (each is an unpacked `actions/runner` with `.runner`/`.credentials`, a
  per-runner `.env`, and a runtime `.gitconfig-ci`). The runner **rewrites its
  own `.env`** (it reorders keys), so keep provisioned entries to bare
  `KEY=VALUE` lines — comments there will not survive.
  **Do not write test fixtures into `runners/`**; use a temp dir.
- `docs/superpowers/` is gitignored (local design specs).

## Verifying changes

`make` runs everything CI runs: `make syntax` parses every script, `make test`
runs every suite in `tests/`, and a bare `make` does both. CI calls the same two
targets on ubuntu-latest and macos-latest, so a green `make` locally is the same
check. Beyond that, validate with:

- `bash -n <script>` for syntax.
- `./register.sh --dry-run`, `./unregister.sh --dry-run`, and
  `./nuke-runners.sh --dry-run` (read-only).
- Stub `gh` on `PATH` to exercise auth/API paths without real calls.
- For `launch.sh` signal handling, test against a mock runner tree in a temp
  dir (a `run.sh` that spawns a long-lived child, *not* via `exec`) and assert
  no processes survive Ctrl+C/Ctrl+D/Ctrl+\/SIGHUP. Test interactively via a
  pty — the interactive path differs from the non-interactive one.
- `./tests/test_process_helpers.sh` — automated tests for the
  `lib/common.sh` process-management helpers (`runner_pids`,
  `stop_orphaned_runners`, `runners_supervised`, `repo_launch_sh_pids`,
  `nuke_runner_processes`, `ensure_runners_stopped`), run against a mock
  runner tree in a temp dir. Run it after touching any of those functions.
  It points `RUNNERS_DIR` and `LAUNCH_PIDFILE` at a temp dir before anything
  can act on them; keep every new test on that path, since these helpers
  SIGKILL what they match.
- `./tests/test_launch_signals.sh` — automated tests for `launch.sh`'s own
  signal handling, sourcing it through its source guard. Run it after touching
  `signal_all`, `any_running`, `cleanup`, or the launch loop.
