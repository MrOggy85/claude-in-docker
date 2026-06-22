# User instructions for Claude Code

Add your personal instructions here. This file is mounted into the container as
~/.claude/CLAUDE.md and applies to every project you run.

## Git
use conventional commit prefixes
Never use compound bash commands (cd && git ...) for git operations. A hook blocks these to prevent bare repository attacks. Instead, use the `--git-dir` or `-C` flag, or run separate bash calls.

## GitHub
Do not use the `gh` CLI. It is intentionally not installed in this container. Use the GitHub MCP server (configured in claude.json) for all GitHub operations — PRs, issues, and API access. The MCP server is authenticated with a fine-grained token scoped to least privilege.

## Docker
Docker is not available inside this container — there is no Docker daemon or CLI on PATH. Do not attempt to run `docker`, `docker compose`, or any container tooling, and do not retry with the sandbox disabled. Instead, give the user the exact commands to run in a separate terminal on the host, and ask them to paste back the output you need.

## YAML validation
Use `yamllint <file>` to validate YAML files. It is installed in the container and available on PATH. For quick syntax-only checks use `yamllint -d "{extends: relaxed, rules: {line-length: disable}}" <file>`.
