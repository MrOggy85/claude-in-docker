# Operate the host chrome-devtools bridge as a macOS launchd agent: install it,
# restart it after a code change, see whether it is actually up, read its log.
# The bridge itself is documented in ../docs/chrome-devtools-mcp.md.
#
# Everything here is launchd-specific and therefore macOS-only, except `smoke`,
# `profiles` and `port`. Run it from anywhere with `make -C chrome-devtools-mcp <target>`.

LABEL   := com.user.claude-chrome-devtools-mcp
PLIST   := $(LABEL).plist
INSTALLED := $(HOME)/Library/LaunchAgents/$(PLIST)
LOG     := /tmp/claude-chrome-devtools-mcp.log
DOMAIN  := gui/$(shell id -u)
SERVICE := $(DOMAIN)/$(LABEL)

# Defaults mirror the bridge's own, so `make status` reports what it actually uses.
PORT         ?= $(or $(CHROME_DEVTOOLS_MCP_PORT),9333)
PROFILE_ROOT ?= $(or $(CHROME_DEVTOOLS_MCP_PROFILE_ROOT),$(HOME)/.cache/claude-in-docker/chrome-profiles)
LINES        ?= 50

.PHONY: help install uninstall restart stop start status log logs port profiles smoke macos

help:
	@echo "Host chrome-devtools bridge (launchd agent $(LABEL))"
	@echo
	@echo "  make install     install the launchd agent, pointed at this checkout"
	@echo "  make uninstall   unload it and remove the plist"
	@echo "  make restart     restart the bridge (picks up code and config changes)"
	@echo "  make stop        unload it; make start loads it again"
	@echo "  make status      is it loaded, is it listening, how many tokens"
	@echo "  make log         last $(LINES) log lines (override with LINES=200)"
	@echo "  make logs        follow the log"
	@echo "  make port        what is listening on $(PORT)"
	@echo "  make profiles    Chrome profiles on disk, with sizes"
	@echo "  make smoke PROJECT=~/code/foo   full MCP handshake for one project"

# launchctl only exists on macOS; fail with a sentence rather than "not found".
macos:
	@[ "$$(uname -s)" = "Darwin" ] || { \
	  echo "This target needs launchd (macOS). On Linux run ./host-chrome-devtools-mcp.sh directly."; \
	  exit 1; }

# The committed plist hardcodes ~/code/claude-in-docker; rewrite that to wherever
# this checkout actually lives, so the installed copy is correct by construction.
install: macos
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@sed 's|<string>exec .*</string>|<string>exec "$(CURDIR)/host-chrome-devtools-mcp.sh"</string>|' \
	  "$(CURDIR)/$(PLIST)" > "$(INSTALLED)"
	@launchctl bootout $(SERVICE) 2>/dev/null || true
	@launchctl bootstrap $(DOMAIN) "$(INSTALLED)"
	@launchctl kickstart -k $(SERVICE)
	@echo ">> installed $(INSTALLED) -> $(CURDIR)/host-chrome-devtools-mcp.sh"

uninstall: macos
	@launchctl bootout $(SERVICE) 2>/dev/null || true
	@rm -f "$(INSTALLED)"
	@echo ">> removed $(INSTALLED)"

# Restarts the process, which re-runs the wrapper — that is what re-exports
# CID_PROJECTS_DIR and picks up an edited host-chrome-devtools-mcp.js. Only a
# change to the plist itself needs `make install` (bootout + bootstrap).
restart: macos
	@launchctl kickstart -k $(SERVICE)
	@echo ">> restarted $(LABEL)"

stop: macos
	@launchctl bootout $(SERVICE) 2>/dev/null || true
	@echo ">> unloaded $(LABEL)"

start: macos
	@launchctl bootstrap $(DOMAIN) "$(INSTALLED)"
	@echo ">> loaded $(LABEL)"

# Three independent questions: is the agent loaded, is something actually bound
# to the port, and does the bridge know about any projects. A loaded agent that
# crash-loops still prints here, with its last exit code.
status:
	@echo "== launchd"
	@launchctl print $(SERVICE) 2>/dev/null \
	  | grep -E '^[[:space:]]*(state|pid|last exit code|path) ' \
	  || echo "   not loaded  (make install)"
	@echo "== port $(PORT)"
	@lsof -nP -iTCP:$(PORT) -sTCP:LISTEN 2>/dev/null || echo "   nothing listening"
	@echo "== tokens"
	@line=$$(grep -E 'token\(s\) loaded|no project tokens' "$(LOG)" 2>/dev/null | tail -1); \
	  if [ -n "$$line" ]; then echo "   $$line"; else echo "   no token line in $(LOG) yet"; fi

log:
	@tail -n $(LINES) "$(LOG)" 2>/dev/null || echo "no log at $(LOG) yet"

logs:
	@tail -f "$(LOG)"

port:
	@lsof -nP -iTCP:$(PORT) -sTCP:LISTEN 2>/dev/null || echo "nothing listening on $(PORT)"

# Sizes matter here: a stale profile is a few hundred MB, and this is the only
# place they are visible (they live outside the config dir, see ../CLAUDE.md).
profiles:
	@du -sh "$(PROFILE_ROOT)"/*/* 2>/dev/null || echo "no profiles yet at $(PROFILE_ROOT)"

# The token identifies the project, so this needs one: make smoke PROJECT=~/code/foo
smoke:
	@[ -n "$(PROJECT)" ] || { echo "usage: make smoke PROJECT=~/code/your-project"; exit 1; }
	@"$(CURDIR)/smoke-test.sh" "$(PROJECT)"
