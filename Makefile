# Config files are created from their committed *.example templates.
# Each file is its own target with no prerequisites, so `make init` creates the
# ones that are missing and leaves existing files (your edits) untouched.

.PHONY: init build test release vet

# ---- Go build ----

# Build both host binaries: `claude` (replaces run.sh) and `claude-usage`
# (replaces usage.sh). The `claude` binary is what the README shell alias
# points at; `claude-usage` is invoked by usage.sh.
build: vet
	go build -o claude ./cmd/claude
	go build -o claude-usage ./cmd/usage

vet:
	go vet ./...

test:
	go test ./...

# Cross-compile for common platforms into dist/.
release: vet
	mkdir -p dist
	GOOS=darwin  GOARCH=arm64 go build -o dist/claude-darwin-arm64  ./cmd/claude
	GOOS=darwin  GOARCH=amd64 go build -o dist/claude-darwin-amd64  ./cmd/claude
	GOOS=linux   GOARCH=arm64 go build -o dist/claude-linux-arm64   ./cmd/claude
	GOOS=linux   GOARCH=amd64 go build -o dist/claude-linux-amd64   ./cmd/claude
	GOOS=darwin  GOARCH=arm64 go build -o dist/claude-usage-darwin-arm64  ./cmd/usage
	GOOS=darwin  GOARCH=amd64 go build -o dist/claude-usage-darwin-amd64  ./cmd/usage
	GOOS=linux   GOARCH=arm64 go build -o dist/claude-usage-linux-arm64   ./cmd/usage
	GOOS=linux   GOARCH=amd64 go build -o dist/claude-usage-linux-amd64   ./cmd/usage

# ---- Config init ----

init: settings.json claude.json container-CLAUDE.md allowed-domains.txt .gitconfig install_additional_packages.sh

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
