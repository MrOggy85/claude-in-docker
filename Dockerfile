# Pin the base image digest for supply-chain security.
# To update after an upstream security patch:
#   docker manifest inspect debian:trixie-slim \
#     | jq -r '.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest'
# Then replace the @sha256:... suffix on the FROM line (or run `make pin-digest`).
# Leave blank (FROM debian:trixie-slim) only in development; always pin in production.
FROM debian:trixie-slim

# Install Node.js 22 from NodeSource (GPG-verified signed apt repository).
# Keeps the Node version under our control rather than inherited from the base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' \
    > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

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
  dnsutils \
  man-db \
  iptables \
  ipset \
  shellcheck \
  nano \
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

# Install Claude Code into /usr/local (readable/executable by every user) as
# root. Because the install is root-owned, the self-updater is disabled so a
# non-root runtime user doesn't fail trying to write to it.
#
# Packages are declared in package.json; both branches below install them to
# /usr/local/node_modules/. npm v10 (shipped with Node 22) places bin symlinks
# in /usr/local/node_modules/.bin/ rather than /usr/local/bin/ for non-global
# installs; PATH is extended below to include that directory. Once
# package-lock.json is committed (`make lockfile`), the build automatically
# switches to `npm ci` for integrity-verified reproducible installs.
#
# ccusage ships its platform-native binary without the executable bit and chmods
# it on first run; that chmod fails with EPERM for the non-root runtime user
# (chmod requires ownership). Set the bit here as root so the binary is already
# executable at runtime and ccusage skips the chmod. The path is arch-specific
# (@ccusage/ccusage-linux-<arch>), so match it by glob.
COPY package.json package-lock.json* /tmp/npm-install/
# Both paths below install to /usr/local/node_modules/ (bin symlinks land in
# /usr/local/node_modules/.bin/, see PATH below). npm ci additionally verifies
# integrity from the lockfile.
# To upgrade from the unlocked fallback to the fully verified path:
#   1. Run `make lockfile` to generate package-lock.json
#   2. Commit it — on the next `docker build`, npm ci will be used automatically.
RUN if [ -f /tmp/npm-install/package-lock.json ]; then \
      cd /tmp/npm-install && npm ci --prefix /usr/local; \
    else \
      jq -r '.dependencies | to_entries[] | "\(.key)@\(.value)"' /tmp/npm-install/package.json \
        | xargs npm install --prefix /usr/local; \
    fi \
 && find /usr/local/node_modules -type f -path '*@ccusage/*/bin/*' -exec chmod a+rx {} + \
 && rm -rf /tmp/npm-install
ENV DISABLE_AUTOUPDATER=1
# npm v10 (Node 22) places bin symlinks for non-global installs in
# node_modules/.bin/ rather than /usr/local/bin/. Extend PATH so that `claude`,
# `ccusage`, `tsc`, etc. are reachable without a full path.
ENV PATH="/usr/local/node_modules/.bin:${PATH}"

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
# code calling getpwuid(). Inject the entry at build time (as root) using the
# caller's UID/GID/username passed via --build-arg, so /etc/passwd and
# /etc/group stay at their default 644 permissions and are never world-writable.
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USERNAME=dev
RUN if ! getent passwd "${USER_ID}" >/dev/null 2>&1; then \
      echo "${USERNAME}:x:${USER_ID}:${GROUP_ID}:${USERNAME}:/home/dev:/bin/bash" >> /etc/passwd; \
    fi \
 && if ! getent group "${GROUP_ID}" >/dev/null 2>&1; then \
      echo "${USERNAME}:x:${GROUP_ID}:" >> /etc/group; \
    fi

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

# User-supplied extra packages. The script is gitignored and created from
# install_additional_packages.sh.example by `make init`; edit it to install
# whatever a workflow needs (e.g. Deno), then rebuild the image. Kept near the
# end so editing it only rebuilds this layer onward.
COPY install_additional_packages.sh /usr/local/bin/install_additional_packages.sh
RUN chmod +x /usr/local/bin/install_additional_packages.sh \
 && /usr/local/bin/install_additional_packages.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

WORKDIR /home/dev/repo

CMD ["claude"]
