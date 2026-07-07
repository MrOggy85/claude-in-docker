# Config files are created from their committed templates in templates/ into a
# dedicated config dir (~/.config/claude-in-docker by default) — NOT the repo, so
# a checkout stays clean. Each file is its own target with no prerequisites, so
# `make init` creates the missing ones and leaves your edits untouched. Override
# the location with CLAUDE_DOCKER_CONFIG_DIR or XDG_CONFIG_HOME (see scripts/paths.sh).
XDG_CONFIG_HOME ?= $(HOME)/.config
CLAUDE_DOCKER_CONFIG_DIR ?= $(XDG_CONFIG_HOME)/claude-in-docker
CONFIG_DIR := $(CLAUDE_DOCKER_CONFIG_DIR)

GLOBAL_CONFIG := settings.json claude.json mcp-servers.json container-CLAUDE.md allowed-domains.txt .gitconfig .gitignore_global .env

.PHONY: init migrate bats test test-extra-mounts test-extra-ports test-run test-e2e test-ext-allowlist lockfile pin-digest proxy-up proxy-down
# install_additional_packages.sh stays in the repo: it is COPY'd into the base
# image at build time (build context = repo dir), so unlike the others it can't
# be mounted from the config dir.
init: $(addprefix $(CONFIG_DIR)/,$(GLOBAL_CONFIG)) $(CONFIG_DIR)/.credentials.json install_additional_packages.sh
	@echo ">> config ready in $(CONFIG_DIR)  (view it with ./config.sh list)"

# Move a pre-existing repo-root config (from older versions of this tool) into
# the config dir. Non-destructive — never overwrites files already there.
migrate:
	./scripts/migrate-config.sh

# Bring up / tear down the centralized egress proxy — the sole egress path for
# every Claude container (see docs/egress-proxy.md). run.sh auto-starts it, but
# running this explicitly is clearer for a long-lived shared service. proxy-up is
# idempotent and re-applies squid.conf / helper edits.
proxy-up:
	./proxy/up.sh

proxy-down:
	docker rm -f "$${CLAUDE_EGRESS_PROXY_NAME:-claude-egress-proxy}" 2>/dev/null || true

# Install bats. Picks the package manager by platform.
#   macOS:           brew install bats-core
#   Debian/Ubuntu:   sudo apt install bats
bats:
	@if [ "$$(uname)" = "Darwin" ]; then \
	  brew install bats-core; \
	else \
	  sudo apt install bats; \
	fi

# Run all bats unit tests.
# Install bats first with `make bats`, or see
# https://bats-core.readthedocs.io/en/stable/installation.html
#   CI: uses .github/workflows/test.yml (bats-core/bats-action)
test:
	@command -v bats >/dev/null 2>&1 || { \
	  echo "bats not found. Install from https://bats-core.readthedocs.io/en/stable/installation.html"; \
	  exit 1; \
	}
	bats test/

test-extra-mounts:
	bats test/extra-mounts.bats

test-extra-ports:
	bats test/extra-ports.bats

test-run:
	bats test/run.bats

test-e2e:
	bats test/e2e.bats

test-ext-allowlist:
	bats test/ext-allowlist.bats

# Generate / refresh package-lock.json from package.json.
# Run this after adding or changing a package in package.json, then commit
# the result. Once package-lock.json is present the Docker build uses
# `npm ci` for integrity-checked reproducible installs.
lockfile:
	npm install --package-lock-only

# Fetch the current amd64 digest of debian:trixie-slim and write it into the
# FROM line of the Dockerfile. Run after upstream security patches, then rebuild.
# Requires docker (or skopeo: replace the command below with
#   skopeo inspect --no-creds docker://debian:trixie-slim | jq -r '.Digest'
# if docker is not available).
pin-digest:
	@DIGEST=$$(docker manifest inspect debian:trixie-slim \
	  | jq -r '.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest') && \
	  sed -i "s|FROM debian:trixie-slim.*|FROM debian:trixie-slim@$$DIGEST|" Dockerfile && \
	  echo "Pinned to $$DIGEST"

# Pattern rule: create any config-dir file from its same-named template. No
# prerequisite on the template, so an existing (edited) file is left untouched.
$(CONFIG_DIR)/%:
	@mkdir -p $(CONFIG_DIR)
	cp templates/$* $@

# Credentials need mode 600. This explicit rule is more specific than the pattern
# rule above, so make prefers it. Seeded "{}" so Docker mounts it as a file;
# `/login` writes the real token in place. Delete it to force a re-login —
# `make init` re-creates it empty.
$(CONFIG_DIR)/.credentials.json:
	@mkdir -p $(CONFIG_DIR)
	cp templates/.credentials.json $@
	chmod 600 $@

# User-supplied extra packages, baked into the base image at build time (see
# Dockerfile). Stays in the repo (gitignored) because it must be in the build
# context. Edit it, then rebuild the image.
install_additional_packages.sh:
	cp templates/install_additional_packages.sh install_additional_packages.sh
	chmod +x install_additional_packages.sh
