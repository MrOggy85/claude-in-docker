# Config files are created from their committed *.example templates.
# Each file is its own target with no prerequisites, so `make init` creates the
# ones that are missing and leaves existing files (your edits) untouched.

.PHONY: init bats test test-extra-mounts test-extra-ports test-run test-e2e
init: settings.json claude.json container-CLAUDE.md allowed-domains.txt .gitconfig install_additional_packages.sh

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

settings.json:
	cp settings.json.example settings.json

claude.json:
	cp claude.json.example claude.json

container-CLAUDE.md:
	cp container-CLAUDE.md.example container-CLAUDE.md

allowed-domains.txt:
	cp allowed-domains.txt.example allowed-domains.txt

.gitconfig:
	cp .gitconfig.example .gitconfig

install_additional_packages.sh:
	cp install_additional_packages.sh.example install_additional_packages.sh
	chmod +x install_additional_packages.sh
