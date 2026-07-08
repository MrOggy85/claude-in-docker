# Pin the base image digest for supply-chain security (blank = dev only).
# Run `make pin-digest` after an upstream patch to append @sha256:... here.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
  git \
  ripgrep \
  jq \
  curl \
  ca-certificates \
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
  man-db \
  nftables \
  shellcheck \
  yamllint \
  nano \
  make \
  sudo \
    && rm -rf /var/lib/apt/lists/*

# Debian ships fd-find and bat under non-canonical names; add the usual aliases.
RUN ln -s "$(command -v fdfind)" /usr/local/bin/fd \
 && ln -s "$(command -v batcat)" /usr/local/bin/bat

# Repos bind-mount as the host UID (no /etc/passwd entry), so git flags them
# "dubious ownership". Mark all mounted repos safe system-wide (the read-only
# ~/.gitconfig mounted at runtime is untouched).
RUN git config --system --add safe.directory '*'

# Writable HOME for the passwd-less non-root runtime UID (see run.sh --user), so
# ~ is world-writable (777). $HOME drives ~/.claude, the npm cache, nvm, etc.
ENV HOME=/home/dev
RUN mkdir -p /home/dev/repo /home/dev/.claude && chmod -R 777 /home/dev

# Node.js via nvm — the SOLE node (no apt node), user-controlled at runtime
# (`nvm install`/`use`, `corepack`, `npm -g`). Under $HOME/.nvm, chmod 777 (not
# chown'd, so the layer stays UID-agnostic and cached). nvm verifies each
# download's SHA-256 (integrity, not GPG).
#
# The stable $NVM_DIR/default symlink puts node on PATH via the ENV below (the
# `claude` entrypoint and non-interactive `bash -c` never source ~/.bashrc) and
# avoids hard-coding the patch version. NODE_VERSION is pinned for
# reproducibility; bump to the current 22.x LTS on upgrades.
ARG NVM_VERSION=v0.40.3
ARG NODE_VERSION=v22.23.1
ENV NVM_DIR=/home/dev/.nvm
# nvm steps run under bash (RUN uses /bin/sh); $NVM_DIR/$NODE_VERSION are inherited.
RUN mkdir -p "$NVM_DIR" \
 && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/nvm.sh" -o "$NVM_DIR/nvm.sh" \
 && bash -c '. "$NVM_DIR/nvm.sh" \
      && nvm install "$NODE_VERSION" \
      && nvm alias default "$NODE_VERSION" \
      && ln -s "versions/node/$(nvm version default)" "$NVM_DIR/default"' \
 && printf 'export NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"\n' >> /home/dev/.bashrc \
 && chmod -R 777 "$NVM_DIR"
# Default node/npm/npx/corepack on PATH for every shell.
ENV PATH="$NVM_DIR/default/bin:${PATH}"

# Install Claude Code + deps to /usr/local as root (readable by all; self-updater
# disabled, DISABLE_AUTOUPDATER below, since the runtime user can't write it).
# The manifest is COPY'd into /usr/local and npm runs there (NOT --prefix, which
# makes `npm ci` read the lockfile from the prefix and miss a cwd copy). With
# package-lock.json committed (`make lockfile`) the build uses `npm ci` for
# verified reproducible installs, else an unlocked fallback from package.json.
#
# ccusage ships its native binary non-executable and chmods it on first run,
# which EPERMs for the non-root user; set the bit here so ccusage skips it. Path
# is arch-specific (@ccusage/ccusage-linux-<arch>), matched by glob.
COPY package.json package-lock.json* /usr/local/
RUN cd /usr/local \
 && if [ -f package-lock.json ]; then npm ci; else npm install; fi \
 && find /usr/local/node_modules -type f -path '*@ccusage/*/bin/*' -exec chmod a+rx {} +
ENV DISABLE_AUTOUPDATER=1
# npm puts dep bin symlinks in node_modules/.bin/; add to PATH so `claude`,
# `ccusage`, `tsc`, etc. resolve without a full path.
ENV PATH="/usr/local/node_modules/.bin:${PATH}"

# Minimal ~/.claude.json baked in (NOT mounted); the ephemeral --rm container
# resets it each run: onboarding done + repo mount pre-trusted (no prompts).
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

# The runtime host UID has no /etc/passwd entry, breaking whoami, os.userInfo(),
# getpwuid(). Inject it from the --build-arg UID/GID/name (keeps /etc/passwd at
# 644). ARGs declared late so they only affect this layer onward — the expensive
# apt/nvm/npm layers above stay cached across builders.
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=dev
RUN if ! getent passwd "${USER_ID}" >/dev/null 2>&1; then \
      echo "${USERNAME}:x:${USER_ID}:${GROUP_ID}:${USERNAME}:/home/dev:/bin/bash" >> /etc/passwd; \
    fi \
 && if ! getent group "${GROUP_ID}" >/dev/null 2>&1; then \
      echo "${USERNAME}:x:${GROUP_ID}:" >> /etc/group; \
    fi

# Egress lock: the entrypoint applies these rules via a sudo rule scoped to only
# this script (no other root escalation). Allowlist policy lives in Squid.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh \
 && printf 'Defaults!/usr/local/bin/init-firewall.sh !pam_acct_mgmt\nALL ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\n' \
      > /etc/sudoers.d/firewall \
 && chmod 0440 /etc/sudoers.d/firewall

# User extra packages: gitignored, created from templates/ by `make init`; baked
# here near the end so edits only rebuild this layer onward. Runs as root, so
# re-apply 777 to /home/dev afterward to keep $HOME user-writable.
COPY install_additional_packages.sh /usr/local/bin/install_additional_packages.sh
RUN chmod +x /usr/local/bin/install_additional_packages.sh \
 && /usr/local/bin/install_additional_packages.sh \
 && chmod -R 777 /home/dev

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

WORKDIR /home/dev/repo

CMD ["claude"]
