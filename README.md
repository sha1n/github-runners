# github-runners

Home for a fleet of [GitHub Actions self-hosted runners](https://docs.github.com/actions/hosting-your-own-runners)
running as native processes on this machine, registered at the **organization**
level.

Two scripts:

- **`register.sh`** — first-time setup: downloads the runner once and registers
  N runners with a single token.
- **`launch.sh`** — starts all registered runners and stops them cleanly on
  `Ctrl+C` / `Ctrl+D`.

## Setup

1. Copy the config template and fill it in:

   ```sh
   cp .env.example .env
   ```

   | Variable                  | Required | Description                                                        |
   |---------------------------|----------|--------------------------------------------------------------------|
   | `GITHUB_ORG`              | yes      | Organization the runners attach to.                                |
   | `RUNNER_TOKEN`            | yes      | Org registration token (Org Settings → Actions → Runners → New).   |
   | `RUNNER_COUNT`            | yes      | How many runners to register/launch.                               |
   | `RUNNER_NAME_PREFIX`      | no       | Name prefix; defaults to this machine's short hostname.            |
   | `RUNNER_LABELS`           | no       | Extra labels, appended to `self-hosted,<os>,<arch>`.               |
   | `RUNNER_DOWNLOAD_VERSION` | no       | Runner release to download; defaults to `latest`.                  |

   The registration token is valid for ~1 hour and is reused for every runner.

2. Register the runners:

   ```sh
   ./register.sh            # download + register
   ./register.sh --dry-run  # preview without contacting GitHub
   ```

3. Launch them:

   ```sh
   ./launch.sh
   ```

   Press `Ctrl+C` or `Ctrl+D` to stop. The runners go offline but stay
   registered, so the next `./launch.sh` is instant.

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
