# Checks for this repository. Every target here is safe to run on a machine
# that has a live fleet: each suite points RUNNERS_DIR and LAUNCH_PIDFILE at a
# temp dir of its own, and no target reads or writes runners/.
#
#   make          syntax-check every script, then run every suite
#   make test     run every suite in tests/
#   make syntax   parse every script without running it

SHELL := /bin/bash

SCRIPTS := $(wildcard *.sh lib/*.sh tests/*.sh tests/fixtures/*.sh)
# Every suite is picked up by name, so a new tests/test_*.sh needs no edit here.
TEST_SUITES := $(wildcard tests/test_*.sh)

.DEFAULT_GOAL := check
.PHONY: check test syntax

check: syntax test

syntax:
	@for f in $(SCRIPTS); do \
	  bash -n "$$f" || exit 1; \
	done
	@echo "syntax ok: $(words $(SCRIPTS)) script(s)"

test:
	@for t in $(TEST_SUITES); do \
	  printf '\n==> %s\n' "$$t"; \
	  "$$t" || exit 1; \
	done
