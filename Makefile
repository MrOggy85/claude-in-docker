# Config files are created from their committed *.example templates.
# Each file is its own target with no prerequisites, so `make init` creates the
# ones that are missing and leaves existing files (your edits) untouched.

.PHONY: init
init: settings.json claude.json CLAUDE.md allowed-domains.txt .gitconfig

settings.json:
	cp settings.json.example settings.json

claude.json:
	cp claude.json.example claude.json

CLAUDE.md:
	cp CLAUDE.md.example CLAUDE.md

allowed-domains.txt:
	cp allowed-domains.txt.example allowed-domains.txt

.gitconfig:
	cp .gitconfig.example .gitconfig
