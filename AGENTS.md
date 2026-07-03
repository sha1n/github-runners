# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

A small Bash toolkit for running a fleet of **GitHub Actions self-hosted
runners** as native processes on one machine, registered at the
**organization** level. Three entry points plus a shared library:

- `register.sh` — first-time setup: download the runner once, register
  `RUNNER_COUNT` runners. Idempotent; no version-update path (runners
  auto-update at runtime). Also provisions each `runners/runner-N/.env` with
  `GIT_CONFIG_GLOBAL` (unless `ISOLATE_GIT_CONFIG=false`) so the
  `safe.directory` entries `actions/checkout` writes via `git config --global`
  stay out of the operator's `~/.gitconfig`.
- `launch.sh` — start all registered runners; stop them cleanly on `Ctrl+C`
  (SIGINT) or `Ctrl+D` (EOF). Uses job control so each runner leads its own
  process group, then signals the group (SIGINT → SIGTERM → SIGKILL).
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
  touching anything.
- `lib/common.sh` — shared helpers, sourced by all four. Logging
  (`info`/`warn`/`die`), `load_env`, `require_vars`, platform detection,
  runner naming, and GitHub auth (`resolve_auth`, `api`, `looks_like_pat`,
  `mint_registration_token`).

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

- Runtime state is gitignored and untracked: `.env`, `runners/`, `.cache/`.
  Never assume `runners/` is empty — it holds real registered runners
  (each is an unpacked `actions/runner` with `.runner`/`.credentials`, a
  per-runner `.env`, and a runtime `.gitconfig-ci`). The runner **rewrites its
  own `.env`** (it reorders keys), so keep provisioned entries to bare
  `KEY=VALUE` lines — comments there will not survive.
  **Do not write test fixtures into `runners/`**; use a temp dir.
- `docs/superpowers/` is gitignored (local design specs).

## Verifying changes

There is no test framework. Validate with:

- `bash -n <script>` for syntax.
- `./register.sh --dry-run` and `./unregister.sh --dry-run` (read-only).
- Stub `gh` on `PATH` to exercise auth/API paths without real calls.
- For `launch.sh` signal handling, test against a mock runner tree in a temp
  dir (a `run.sh` that spawns a long-lived child, *not* via `exec`) and assert
  no processes survive Ctrl+C/Ctrl+D. Test interactively via a pty — the
  interactive path differs from the non-interactive one.
