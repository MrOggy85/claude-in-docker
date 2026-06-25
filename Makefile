# Config files are created from their committed templates in templates/.
# Each file is its own target with no prerequisites, so `make init` creates the
# ones that are missing and leaves existing files (your edits) untouched.

.PHONY: init bats test test-extra-mounts test-extra-ports test-run test-e2e lockfile pin-digest
init: settings.json claude.json mcp-servers.json .credentials.json container-CLAUDE.md allowed-domains.txt .gitconfig .gitignore_global install_additional_packages.sh

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

settings.json:
	cp templates/settings.json settings.json

claude.json:
	cp templates/claude.json claude.json

# MCP server definitions, kept separate from the mutable claude.json state file
# and injected at runtime via `claude --mcp-config` (run.sh step 3a). Edit this
# file to add/remove servers; changes apply on the next container start.
mcp-servers.json:
	cp templates/mcp-servers.json mcp-servers.json

# Credentials persist across projects via this single file, bind-mounted
# read-write into the container by run.sh. Seeded "{}" (mode 600) so Docker
# mounts it as a file; `/login` writes the real token in place. Delete it to
# force a re-login — `make init` re-creates it empty.
.credentials.json:
	cp templates/.credentials.json .credentials.json
	chmod 600 .credentials.json

container-CLAUDE.md:
	cp templates/container-CLAUDE.md container-CLAUDE.md

allowed-domains.txt:
	cp templates/allowed-domains.txt allowed-domains.txt

.gitconfig:
	cp templates/.gitconfig .gitconfig

# Global (user-level) gitignore, mounted read-only at ~/.config/git/ignore inside
# the container (git's XDG convention — no core.excludesFile entry needed).
.gitignore_global:
	cp templates/.gitignore_global .gitignore_global

install_additional_packages.sh:
	cp templates/install_additional_packages.sh install_additional_packages.sh
	chmod +x install_additional_packages.sh
