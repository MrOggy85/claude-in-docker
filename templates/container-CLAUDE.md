# User instructions for Claude Code

Add your personal instructions here. This file is mounted into the container as
~/.claude/CLAUDE.md and applies to every project you run.

## Git
use conventional commit prefixes
Never use compound bash commands (cd && git ...) for git operations. A hook blocks these to prevent bare repository attacks. Instead, use the `--git-dir` or `-C` flag, or run separate bash calls.

## GitHub
Do not use the `gh` CLI. It is intentionally not installed in this container. Use the GitHub MCP server (configured in claude.json) for all GitHub operations — PRs, issues, and API access. The MCP server is authenticated with a fine-grained token scoped to least privilege.

## Docker
There is no Docker daemon or CLI inside this container. Do not attempt to run `docker`, `docker compose`, or any container tooling on PATH, and do not retry with the sandbox disabled.

For **inspecting** host containers, use the `docker` MCP server if it is connected (check `/mcp`): `docker_ps`, `docker_logs`, `docker_stats`. Only containers the user has allowlisted are visible, so an empty `docker_ps` means "not allowlisted" at least as often as "not running" — if something you expect is missing, say so and suggest `cid containers add <name>` rather than assuming the container is down.

For anything that **changes** state — build, run, compose up/down, exec, restart, rm — there is no tool. Give the user the exact command to run in a terminal on the host and ask them to paste back the output you need.

## YAML validation
Use `yamllint <file>` to validate YAML files. It is installed in the container and available on PATH. For quick syntax-only checks use `yamllint -d "{extends: relaxed, rules: {line-length: disable}}" <file>`.
