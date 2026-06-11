# Config files are created from their committed *.example templates.
# `make init` copies any that don't exist yet; it never overwrites your edits.
TEMPLATES := settings.json claude.json CLAUDE.md allowed-domains.txt .gitconfig

.PHONY: init
init: ## Copy *.example templates to their target files (skips files that already exist)
	@for f in $(TEMPLATES); do \
	  if [ -e "$$f" ]; then \
	    echo "skip   $$f (already exists)"; \
	  elif [ -e "$$f.example" ]; then \
	    cp "$$f.example" "$$f" && echo "create $$f"; \
	  else \
	    echo "warn   $$f.example missing" >&2; \
	  fi; \
	done
