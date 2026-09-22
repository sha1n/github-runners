# The host-tool manifest for this machine's runners. A GitHub-hosted runner
# gets its tools from the runner image; a self-hosted host is its own image,
# and this file declares it. `brew bundle` installs what is missing and
# upgrades what is listed.
#
# Not here on purpose:
# - go: actions/setup-go gives each job its own pinned toolchain.
# - shellcheck, ruff, golangci-lint: each repo's workflow pins and installs
#   its own lint tools (via pipx or `go tool`), so their versions never
#   depend on this host.

brew "git"       # actions/checkout drives the host git
brew "gh"        # register.sh and unregister.sh call the GitHub API through it
brew "jq"        # JSON parsing in the fleet scripts and in jobs
brew "pipx"      # workflows install their pinned Python tools through it
brew "make"
brew "coreutils"
