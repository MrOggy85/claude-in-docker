# Config files are copied from templates/ into a dedicated config dir (NOT the
# repo, so a checkout stays clean). Each file is its own prerequisite-less target,
# so `make init` creates missing ones and leaves your edits untouched. Override
# the location with CLAUDE_DOCKER_CONFIG_DIR or XDG_CONFIG_HOME.
XDG_CONFIG_HOME ?= $(HOME)/.config
CLAUDE_DOCKER_CONFIG_DIR ?= $(XDG_CONFIG_HOME)/claude-in-docker
CONFIG_DIR := $(CLAUDE_DOCKER_CONFIG_DIR)

GLOBAL_CONFIG := settings.json claude.json mcp-servers.json container-CLAUDE.md allowed-domains.txt .gitconfig .gitignore_global .env

.PHONY: init migrate bats test test-extra-mounts test-extra-ports test-run test-e2e test-ext-allowlist test-chrome-devtools-mcp test-cid lockfile pin-digest proxy-up proxy-down
# install_additional_packages.sh stays in the repo: it is COPY'd into the base
# image at build time (build context = repo dir), so it can't be mounted.
init: $(addprefix $(CONFIG_DIR)/,$(GLOBAL_CONFIG)) $(CONFIG_DIR)/.credentials.json install_additional_packages.sh
	@echo ">> config ready in $(CONFIG_DIR)  (view it with ./cid list)"

# Move a pre-existing repo-root config (from older versions of this tool) into
# the config dir. Non-destructive — never overwrites files already there.
migrate:
	./scripts/migrate-config.sh

# Bring up / tear down the centralized egress proxy (see docs/egress-proxy.md).
# run.sh auto-starts it; running this explicitly is clearer for a long-lived
# shared service. proxy-up is idempotent and re-applies squid.conf / helper edits.
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

# Run all bats unit tests. Install bats first with `make bats`.
# CI: .github/workflows/test.yml (bats-core/bats-action)
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

test-chrome-devtools-mcp:
	bats test/chrome-devtools-mcp.bats

test-cid:
	bats test/cid.bats

# Refresh package-lock.json from package.json (run after changing a package,
# then commit). Once present, the Docker build uses `npm ci` for reproducible installs.
lockfile:
	npm install --package-lock-only

# Fetch the current amd64 digest of debian:trixie-slim into the Dockerfile FROM
# line. Run after upstream security patches, then rebuild. Requires docker (or
# swap in `skopeo inspect --no-creds docker://debian:trixie-slim | jq -r '.Digest'`).
pin-digest:
	@DIGEST=$$(docker manifest inspect debian:trixie-slim \
	  | jq -r '.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest') && \
	  sed -i "s|FROM debian:trixie-slim.*|FROM debian:trixie-slim@$$DIGEST|" Dockerfile && \
	  echo "Pinned to $$DIGEST"

# Pattern rule: create any config-dir file from its same-named template. No
# template prerequisite, so an existing (edited) file is left untouched.
$(CONFIG_DIR)/%:
	@mkdir -p $(CONFIG_DIR)
	cp templates/$* $@

# Credentials need mode 600 — this rule is more specific than the pattern above,
# so make prefers it. Seeded "{}" so Docker mounts it as a file; `/login` writes
# the real token in place. Delete it to force a re-login.
$(CONFIG_DIR)/.credentials.json:
	@mkdir -p $(CONFIG_DIR)
	cp templates/.credentials.json $@
	chmod 600 $@

# User-supplied extra packages, baked into the base image at build time. Stays
# in the repo (gitignored) because it must be in the build context. Edit, then rebuild.
install_additional_packages.sh:
	cp templates/install_additional_packages.sh install_additional_packages.sh
	chmod +x install_additional_packages.sh
