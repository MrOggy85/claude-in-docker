# Pin the base image digest for supply-chain security (blank = dev only).
# Run `make pin-digest` after an upstream patch to append @sha256:... here.
FROM debian:trixie-slim

# zsh is here as a parser, not the shell (that stays bash): shellcheck cannot read
# zsh, so `zsh -n` is the only way to syntax-check completions/_cid from a session.
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
  zsh \
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

# uv — Debian's python3 has neither pip nor a working venv and the runtime user
# cannot apt-get them. Above the npm layer so a claude bump won't re-fetch it.
ARG UV_VERSION=0.12.5
RUN curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

# Install Claude Code + deps to /usr/local as root (readable by all; self-updater
# off via DISABLE_AUTOUPDATER below, since the runtime user can't write it).
# npm runs in /usr/local (NOT --prefix, which reads the lock from the prefix).
# `npm ci` needs the committed package-lock.json for a reproducible install; the
# build fails without it. To bump Claude Code, see docs/updating-claude-code.md.
#
# ccusage ships its native binary non-executable and chmods it on first run,
# which EPERMs for the non-root user; set the bit here so ccusage skips it. Path
# is arch-specific (@ccusage/ccusage-linux-<arch>), matched by glob.
COPY package.json package-lock.json /usr/local/
RUN cd /usr/local \
 && npm ci \
 && find /usr/local/node_modules -type f -path '*@ccusage/*/bin/*' -exec chmod a+rx {} +
ENV DISABLE_AUTOUPDATER=1
# Suppress the feedback survey and non-essential telemetry/traffic.
ENV CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
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

# In-container browser — OPT-IN, off by default (run.sh passes WITH_BROWSER=1 for
# CLAUDE_BROWSER=1 and folds the flag into the context hash, so flipping it
# rebuilds). Adds ~700 MB, hence the gate. Above install_additional_packages.sh
# and the CA layer so neither is invalidated by a browser rebuild.
#
# Chromium comes from Playwright, not apt: --with-deps installs the exact shared
# libraries and fonts that build needs, and the version always matches the driver.
# `playwright` is installed globally alongside the CLI (rather than reached
# through @playwright/cli's nested copy) so the `playwright` bin lands on PATH.
# Both are pinned to the same version — the CLI depends on that exact build.
# PLAYWRIGHT_BROWSERS_PATH puts the download in /opt, readable by any UID,
# instead of root's ~/.cache where the runtime user could not reach it.
# libnss3-tools is for certutil (see the NSS layer below); openbox is a window
# manager, without which Chromium's window cannot be moved or resized over VNC.
# See docs/browser-vnc.md.
ARG WITH_BROWSER=0
ARG PLAYWRIGHT_CLI_VERSION=0.1.19
ARG PLAYWRIGHT_VERSION=1.63.0-alpha-2026-08-31
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# X's socket directory, created HERE because this layer runs as root and Xvfb
# wants it root-owned: created at runtime instead it works, but every start
# prints "Owner of /tmp/.X11-unix should be set to root". entrypoint.sh still
# creates it as a fallback, for the case where /tmp is a fresh mount.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
RUN if [ "${WITH_BROWSER}" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
           xvfb x11vnc novnc websockify openbox libnss3-tools \
      && npm install -g \
           "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}" \
           "playwright@${PLAYWRIGHT_VERSION}" \
      && playwright install --with-deps chromium \
      && chmod -R a+rX /opt/ms-playwright \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Wrapper so every playwright-cli call picks up the generated config (proxy
# credentials — Squid requires auth and Chromium cannot carry it on the command
# line; see docs/browser-vnc.md#egress). Its own dir, prepended to PATH: npm's
# global bin is $NVM_DIR/default/bin, which already outranks /usr/local/bin, so a
# wrapper there would be shadowed by the very binary it wraps. A real file rather
# than a heredoc so `make lint` and test/playwright-wrapper.bats can reach it —
# the flag it injects is only valid on two subcommands, which is exactly the kind
# of thing that needs a test. Harmless when the browser layer is off: it exits
# 127 with a pointer to CLAUDE_BROWSER=1.
ENV PATH="/usr/local/claude-bin:${PATH}"
COPY scripts/playwright-cli.sh /usr/local/claude-bin/playwright-cli
RUN chmod 755 /usr/local/claude-bin/playwright-cli

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

# Trust the egress proxy's CA, so the intercepted TLS it presents (see
# docs/tls-inspection.md) validates. Only the PUBLIC certificate is here — the key
# never leaves the host and the proxy container. run.sh syncs this file from
# <config-dir>/ca/ca.crt into the build context on every run and includes it in
# the context hash, so rotating the CA rebuilds from this layer down. Nothing
# above needs it: `docker build` egresses directly, not through the proxy.
#
# The system store covers OpenSSL, GnuTLS, curl and git in one place. Guarded on
# non-empty, so a build with no config dir (CI, see .github/workflows/image.yml)
# takes the placeholder and leaves the bundle alone. NODE_EXTRA_CA_CERTS is NOT
# set here — run.sh sets it, since Node warns on every process when it points at
# a file that does not exist.
COPY egress-ca.crt /tmp/egress-ca.crt
RUN if [ -s /tmp/egress-ca.crt ]; then \
      install -m 644 /tmp/egress-ca.crt /usr/local/share/ca-certificates/claude-egress-ca.crt \
      && update-ca-certificates; \
    fi; \
    rm -f /tmp/egress-ca.crt
# Chromium is another runtime with its own store: it reads the NSS db at
# ~/.pki/nssdb, not /etc/ssl/certs, so seed the CA there too or every bumped
# HTTPS handshake fails with ERR_CERT_AUTHORITY_INVALID. Below the CA layer on
# purpose — rotating the CA rebuilds from there down, re-seeding this db with it.
# 777 afterwards for the same reason as the layer above: this runs as root but
# the db is read (and locked) by the runtime user. See docs/tls-inspection.md.
RUN if [ "${WITH_BROWSER}" = "1" ] \
    && [ -s /usr/local/share/ca-certificates/claude-egress-ca.crt ]; then \
      mkdir -p /home/dev/.pki/nssdb \
      && certutil -N --empty-password -d sql:/home/dev/.pki/nssdb \
      && certutil -A -n claude-egress-ca -t C,, -d sql:/home/dev/.pki/nssdb \
           -i /usr/local/share/ca-certificates/claude-egress-ca.crt \
      && chmod -R 777 /home/dev/.pki; \
    fi

# Runtimes carrying their own CA bundle instead of reading the system store: point
# them at the merged system bundle (a superset — this never narrows trust). uv and
# httpx read SSL_CERT_FILE, pip reads REQUESTS_CA_BUNDLE. Node reads neither.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

WORKDIR /home/dev/repo

CMD ["claude"]
