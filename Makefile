# Config files are created from their committed *.example templates.
# Each file is its own target with no prerequisites, so `make init` creates the
# ones that are missing and leaves existing files (your edits) untouched.

.PHONY: init
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
