FROM node:22-trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
  git \
  ripgrep \
  jq \
  curl \
  ca-certificates \
  build-essential \
  python3 \
  less \
  procps \
  openssh-client \
  fd-find \
  bat \
  git-delta \
  tree \
  unzip \
  zip \
  xz-utils \
  wget \
  sqlite3 \
  gnupg \
  dnsutils \
  man-db \
  iptables \
  ipset \
  shellcheck \
  sudo \
    && rm -rf /var/lib/apt/lists/*

# Debian ships fd-find and bat under non-canonical names; add the usual aliases.
RUN ln -s "$(command -v fdfind)" /usr/local/bin/fd \
 && ln -s "$(command -v batcat)" /usr/local/bin/bat

# The repo is bind-mounted and owned by the host UID, which usually has no
# /etc/passwd entry; git then flags the worktree as "dubious ownership" and
# aborts. Mark all mounted repos safe at the system level (doesn't touch the
# read-only ~/.gitconfig mounted at runtime).
RUN git config --system --add safe.directory '*'

# Install Claude Code globally as root, into /usr/local (readable/executable by
# every user). Because the install is root-owned, we disable the self-updater so
# a non-root runtime user doesn't fail trying to write to it.
RUN npm install -g @anthropic-ai/claude-code typescript
ENV DISABLE_AUTOUPDATER=1

# We run the container with `--user <your-host-uid>:<gid>` (see run.sh). That UID
# usually has no /etc/passwd entry, so we give it a HOME that any UID can write
# to. Node's os.homedir() and "~" resolve via $HOME, so ~/.claude, the npm cache,
# etc. all land under /home/dev.
ENV HOME=/home/dev
RUN mkdir -p /home/dev/repo /home/dev/.claude && chmod -R 777 /home/dev

# Minimal ~/.claude.json baked into the image (NOT mounted from the host). Because
# the container is ephemeral (--rm), this resets to a clean state every run:
#   - onboarding marked complete (no setup wizard)
#   - the repo's fixed mount path pre-trusted (no "trust this folder?" prompt)
RUN cat > /home/dev/.claude.json <<'JSON'
{
  "hasCompletedOnboarding": true,
  "projects": {
    "/home/dev/repo": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true
    }
  }
}
JSON

RUN chmod -R 777 /home/dev

# The container runs as the host UID (see run.sh --user flag), which usually
# has no /etc/passwd entry. That breaks whoami, Node's os.userInfo(), and any
# code calling getpwuid(). Make /etc/passwd writable and inject an entry for
# the runtime UID at container start.
RUN chmod 666 /etc/passwd /etc/group

# Outbound firewall: allowed domains are baked in at build time; rules are
# applied on each container start via a sudo-scoped call in the entrypoint.
# The sudo rule is restricted to this one script so no other root escalation
# is possible.
COPY allowed-domains.txt /etc/allowed-domains.txt
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh \
 && printf 'Defaults!/usr/local/bin/init-firewall.sh !pam_acct_mgmt\nALL ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\n' \
      > /etc/sudoers.d/firewall \
 && chmod 0440 /etc/sudoers.d/firewall

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

WORKDIR /home/dev/repo

CMD ["claude"]
