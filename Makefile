# Config files are copied from templates/ into a dedicated config dir (NOT the
# repo, so a checkout stays clean). Each file is its own prerequisite-less target,
# so `make init` creates missing ones and leaves your edits untouched. Override
# the location with CLAUDE_DOCKER_CONFIG_DIR or XDG_CONFIG_HOME.
XDG_CONFIG_HOME ?= $(HOME)/.config
CLAUDE_DOCKER_CONFIG_DIR ?= $(XDG_CONFIG_HOME)/claude-in-docker
CONFIG_DIR := $(CLAUDE_DOCKER_CONFIG_DIR)

GLOBAL_CONFIG := settings.json claude.json mcp-servers.json container-CLAUDE.md allowed-domains.txt splice-domains.txt .gitconfig .gitignore_global .env

# Everything `make lint` shellchecks. Globbed per directory so a new script is
# picked up automatically; extend the list when a new script *directory* appears.
# Two deliberate omissions: e2e/scenarios/ (fixtures that are malformed on
# purpose) and the gitignored root install_additional_packages.sh (a user's own
# file — linting it would make local results diverge from CI).
SHELL_SOURCES := cid \
  $(filter-out install_additional_packages.sh,$(wildcard *.sh)) \
  $(wildcard guards/*.sh) $(wildcard scripts/*.sh) $(wildcard proxy/*.sh) \
  $(wildcard docker-bridge/*.sh) $(wildcard chrome-devtools-mcp/*.sh) \
  $(wildcard sound-effects/*.sh) $(wildcard templates/*.sh) \
  $(wildcard skills/*/*.sh)

.PHONY: init ca migrate bats test test-extra-mounts test-extra-ports test-path-volumes test-run test-e2e test-ext-allowlist test-gen-ca test-chrome-devtools-mcp test-docker-bridge test-guards test-scan-settings test-cid test-colors test-sandbox-info test-release lint lockfile update-claude pin-digest proxy-up proxy-down release

# install_additional_packages.sh and egress-ca.crt stay in the repo: both are
# COPY'd into the base image at build time (build context = repo dir), so they
# can't be mounted. TLS interception is mandatory, so `ca` is part of init.
init: $(addprefix $(CONFIG_DIR)/,$(GLOBAL_CONFIG)) $(CONFIG_DIR)/.credentials.json install_additional_packages.sh ca
	@echo ">> config ready in $(CONFIG_DIR)  (view it with ./cid list)"

# Generate the CA the egress proxy signs intercepted TLS with (idempotent — an
# existing CA is left alone). Rotate by deleting $(CONFIG_DIR)/ca and re-running,
# then `make proxy-up`. See docs/tls-inspection.md.
ca:
	./scripts/gen-ca.sh

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
# CI: .github/workflows/test.yml, which pins bats 1.14.0 — apt/brew may hand you
# an older one, so a green `make test` is not quite proof of a green CI.
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

test-path-volumes:
	bats test/path-volumes.bats

test-run:
	bats test/run.bats

test-e2e:
	bats test/e2e.bats

test-ext-allowlist:
	bats test/ext-allowlist.bats

test-gen-ca:
	bats test/gen-ca.bats

test-chrome-devtools-mcp:
	bats test/chrome-devtools-mcp.bats

test-docker-bridge:
	bats test/docker-bridge.bats

test-guards:
	bats test/guards.bats

test-scan-settings:
	bats test/scan-project-settings.bats

test-cid:
	bats test/cid.bats

test-colors:
	bats test/colors.bats

test-sandbox-info:
	bats test/sandbox-info.bats

test-release:
	bats test/release.bats

# Shellcheck every script in SHELL_SOURCES. -x follows `source`d files so
# paths.sh's helpers are known. Zero exclusions: a finding is either fixed or
# silenced at the site with an inline `# shellcheck disable=` and a reason.
# CI: .github/workflows/test.yml
lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "shellcheck not found. Install with 'sudo apt install shellcheck' or 'brew install shellcheck'"; \
	  exit 1; \
	}
	shellcheck -x $(SHELL_SOURCES)

# Regenerate package-lock.json from package.json (run after adding/removing a
# package, then commit). Does NOT bump an already-pinned version — npm treats the
# locked version as satisfying the `latest` tag. Use `make update-claude` to upgrade.
lockfile:
	npm install --package-lock-only

# Bump @anthropic-ai/claude-code to the latest published version in the lockfile
# (package.json stays "latest"; only the lock's pin moves). Commit the result;
# the next `run.sh` rebuilds the image. See docs/updating-claude-code.md.
update-claude:
	npm update @anthropic-ai/claude-code --package-lock-only

# Fetch the current amd64 digest of debian:trixie-slim into the FROM line of BOTH
# Dockerfiles (the base image and the egress proxy share the base). Run after
# upstream security patches, then rebuild. Requires docker (or swap in
# `skopeo inspect --no-creds docker://debian:trixie-slim | jq -r '.Digest'`).
# sed to a temp file then mv: `sed -i` alone is GNU-only (BSD/macOS sed reads the
# next argument as a mandatory backup suffix and would eat "s|FROM ...").
pin-digest:
	@DIGEST=$$(docker manifest inspect debian:trixie-slim \
	  | jq -r '.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest') && \
	  for f in Dockerfile proxy/Dockerfile; do \
	    sed "s|FROM debian:trixie-slim.*|FROM debian:trixie-slim@$$DIGEST|" $$f > $$f.tmp && \
	    mv $$f.tmp $$f; \
	  done && \
	  echo "Pinned both Dockerfiles to $$DIGEST"

# Cut a release: derive the next version from the Conventional Commits since the
# last tag, prepend a CHANGELOG.md section, commit it and annotate the tag.
# Deliberately does not push — the tag push is what makes CI create the GitHub
# Release. Preview with `make release DRY_RUN=1`. See docs/releasing.md.
#
# No `export` needed for VERSION / DRY_RUN / INTRO_FILE / ALLOW_BRANCH: make puts
# command-line variables in the recipe environment already, and an `export` of an
# unset one hands every recipe an empty-but-defined variable instead.
release:
	./scripts/release.sh

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

# Public half of the egress CA, in the build context for the same reason (the
# Dockerfile COPYs it into the container trust store). run.sh writes it from
# $(CONFIG_DIR)/ca/ca.crt on every run; this target only creates the empty
# placeholder a config-less build needs, so the COPY resolves in CI.
egress-ca.crt:
	touch egress-ca.crt
