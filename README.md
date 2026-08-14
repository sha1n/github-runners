# github-runners

Home for a fleet of [GitHub Actions self-hosted runners](https://docs.github.com/actions/hosting-your-own-runners)
running as native processes on this machine, registered at the **organization**
level.

Five scripts:

- **`register.sh`** — first-time setup: downloads the runner once and registers
  N runners.
- **`launch.sh`** — starts all registered runners and stops them cleanly on
  `Ctrl+C`, `Ctrl+D`, `Ctrl+\`, a closed terminal, or an error exit.
- **`unregister.sh`** — deregisters this machine's runners from the org.
- **`fix-zombie-runners.sh`** — detects and recovers runners stuck with a
  stale GitHub session (see [Zombie runners](#zombie-runners)).
- **`nuke-runners.sh`** — force-stops a live `launch.sh` and every runner
  process, for when they've been orphaned (see
  [Orphaned runners](#orphaned-runners)).

## Setup

1. Copy the config template and fill it in. `.env` holds **non-secret config
   only** — the credential is supplied separately (see [Authentication](#authentication)):

   ```sh
   cp .env.example .env
   ```

   | Variable                  | Required | Description                                             |
   |---------------------------|----------|---------------------------------------------------------|
   | `GITHUB_ORG`              | yes      | Organization the runners attach to.                     |
   | `RUNNER_COUNT`            | yes      | How many runners to register/launch.                    |
   | `RUNNER_NAME_PREFIX`      | no       | Name prefix; defaults to this machine's short hostname. |
   | `RUNNER_LABELS`           | no       | Extra labels, appended to `self-hosted,<os>,<arch>`.    |
   | `RUNNER_DOWNLOAD_VERSION` | no       | Runner release to download; defaults to `latest`.       |

2. Register the runners:

   ```sh
   ./register.sh            # download + register
   ./register.sh --dry-run  # preview without contacting GitHub
   ```

3. Launch them:

   ```sh
   ./launch.sh
   ```

   Stop with `Ctrl+C`, `Ctrl+D`, or `Ctrl+\`; closing the terminal or an
   error exit stops them the same way. The runners go offline but stay
   registered, so the next `./launch.sh` is instant.

## Authentication

The credential is read from your **shell environment**, never from `.env`, so
the secret is not persisted to disk. Provide it either way:

- **`gh` CLI (recommended).** Run `gh auth login` once; both scripts use it
  automatically. Add the required scope with:

  ```sh
  gh auth refresh -h github.com -s admin:org
  ```

- **`RUNNER_TOKEN` env var.** Export it (or prefix the command). It accepts
  **either** kind of token interchangeably — the script detects which by its
  format (PATs have a `ghp_`/`github_pat_`/… prefix; registration tokens don't):

  | `RUNNER_TOKEN` value                            | `register.sh`                              | `unregister.sh`            |
  |-------------------------------------------------|--------------------------------------------|----------------------------|
  | **PAT** (`admin:org` / `manage_runners:org`)    | exchanged via API for a registration token | used directly for the API  |
  | **Registration token** (Org → Runners → New)    | passed straight to `config.sh`             | not usable (needs a PAT)   |

  ```sh
  export RUNNER_TOKEN=ghp_xxxxxxxx     # PAT: works for both scripts
  # or, one-off:
  RUNNER_TOKEN=ghp_xxxxxxxx ./register.sh
  ```

Resolution order: `register.sh` prefers an explicit `RUNNER_TOKEN`, else falls
back to `gh`; `unregister.sh` prefers `gh`, else a PAT in `RUNNER_TOKEN`. A
registration token is short-lived (~1 hour); a PAT is reusable. If you put
`RUNNER_TOKEN` in `.env`, `register.sh` warns you to move it to your shell.

## Unregister

To remove this machine's runners from the organization (the counterpart to
`register.sh`):

```sh
./unregister.sh            # confirm, then deregister + clean local config
./unregister.sh --dry-run  # show what would be removed, contact nothing
./unregister.sh --yes      # skip the confirmation prompt
./unregister.sh --purge    # also delete the runners/runner-N directories
```

It deletes every org runner whose name matches this machine's prefix
(`<prefix>-N`) via the GitHub API, then clears each local runner's
configuration (binaries are kept unless `--purge`).

This needs API access — a `gh` login or a PAT in `RUNNER_TOKEN`, both with the
`admin:org` (or `manage_runners:org`) scope — see [Authentication](#authentication).
Stop `launch.sh` before unregistering; the script refuses to run while any
runner process is alive.

## Zombie runners

If a runner process dies without a clean shutdown (crash, `SIGKILL`, the host
sleeping), GitHub's broker can be left holding a stale session for it. The
next `run.sh` then loops forever, and its `_diag/Runner_*.log` shows:

```
TaskAgentSessionConflictException: Error: Conflict
The session for this runner already exists.
```

Fix it with:

```sh
./fix-zombie-runners.sh            # detect + fix, then re-register via register.sh
./fix-zombie-runners.sh --dry-run  # show which runners are stuck, fix nothing
```

It clears the local files that block re-registration (including
`.runner_migrated`, a broker-migration marker that makes `config.sh` refuse to
reconfigure even after `.runner`/`.credentials` are removed) and re-registers
via `register.sh` with `--replace`, which clears the stuck session on GitHub's
side too. It refuses to run only while `launch.sh` is actively supervising
the runners; if they're alive but orphaned, it stops them itself first.

## Orphaned runners

If something kills the terminal holding `launch.sh` outright — `SIGKILL`, a
power loss — none of its signal traps get to run, and the runner processes it
started are left behind with no supervisor. Each surviving `Runner.Listener`
keeps its GitHub broker session alive, so the next `./launch.sh` hits the same
conflict as a [zombie runner](#zombie-runners), except waiting won't clear it:
the session is live, not stale.

Recover with:

```sh
./nuke-runners.sh            # confirm, then stop launch.sh and all runner processes
./nuke-runners.sh --dry-run  # show what would be stopped, stop nothing
./nuke-runners.sh --yes      # skip the confirmation prompt
```

Both scripts stop orphaned runner processes on their own, so that isn't what
decides between them. `fix-zombie-runners.sh` refuses to touch a `launch.sh`
that's still alive and supervising — `nuke-runners.sh` doesn't; it stops that
`launch.sh` too, along with everything under it, making no GitHub call and
changing no file. Reach for it first whenever `launch.sh` itself is stuck
retrying, or you just want a clean slate with nothing touching the network.
Reach for `fix-zombie-runners.sh` once no `launch.sh` is in the way and the
conflict is still there — a session genuinely stale on GitHub's side, which
only clearing the local registration and re-registering through
`register.sh` (and its GitHub authentication) can fix.

## How it works

- The platform (macOS/Linux, arm64/x64) is auto-detected and the matching
  runner tarball is downloaded into `.cache/` once, then verified against the
  SHA-256 GitHub publishes for that release.
- Each runner gets its own directory under `runners/runner-N/`, named
  `<prefix>-N`.
- `register.sh` is idempotent: re-running it only fills in missing or
  unconfigured runners. There is **no version-update path** because live
  runners keep themselves current via GitHub's built-in auto-update.

## Notes

- **Linux:** the runner needs some system libraries. If `config.sh` complains,
  run `runners/runner-1/bin/installdependencies.sh` (needs `sudo`) once.
- Secrets and runtime state (`.env`, `runners/`, `.cache/`) are gitignored.
- **Isolated git config:** `register.sh` writes `GIT_CONFIG_GLOBAL` into each
  `runners/runner-N/.env`, pointing at a throwaway `.gitconfig-ci` in the
  runner's own dir. This keeps the `safe.directory` entries that
  `actions/checkout` adds with `git config --global` out of your real
  `~/.gitconfig` — they would otherwise accumulate there because checkout's
  cleanup step is skipped whenever a job is killed. The file is created by git
  on first use; nothing is copied from `~/.gitconfig`.
