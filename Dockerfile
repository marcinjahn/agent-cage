# agent-cage base image (see DESIGN.md §5).
#
# Host-agnostic: contains nothing host-specific. The user's nvim config, mason
# formatters, credentials and VCS identity are bind-mounted at runtime by the
# wrappers (DESIGN §7/§9), never baked in.
#
# Built daily by GitHub Actions and pushed to GHCR. Fedora 43 must match the
# host so that the mounted, ABI-sensitive mason-compiled formatters run.
FROM fedora:43

# Pinned tool versions are intentionally avoided: the daily rebuild tracks
# latest. Channels/minor lines that must stay fixed are set as ARGs here.
ARG DOTNET_CHANNEL=10.0

# pipefail so a failed `curl` in a `curl … | bash` pipeline aborts the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
# neovim + libnotify drive the formatting and notification hooks; fuse-overlayfs
# is for the rootless docker sidecar's storage; the build basics let mason/npm
# compile anything not already prebuilt in the mounted data dir.
RUN dnf -y install \
        bash ca-certificates curl tar xz unzip findutils which procps-ng \
        git jq \
        neovim libnotify \
        gcc gcc-c++ make \
        fuse-overlayfs \
    && dnf clean all

# GitHub CLI from the official repo (tracks latest).
RUN curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo \
        -o /etc/yum.repos.d/gh-cli.repo \
    && dnf -y install gh \
    && dnf clean all

# Docker CLI (client only — the daemon is the sidecar, DESIGN §8) from Docker's repo.
RUN curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo \
        -o /etc/yum.repos.d/docker-ce.repo \
    && dnf -y install docker-ce-cli \
    && dnf clean all

# kubectl — latest stable, fetched directly (not in Fedora repos).
RUN KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
    && curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# acli (Atlassian CLI) — per Atlassian's Linux instructions (single static binary).
RUN curl -fsSL "https://acli.atlassian.com/linux/latest/acli_linux_amd64/acli" \
        -o /usr/local/bin/acli \
    && chmod +x /usr/local/bin/acli

# jj (jujutsu) — latest release, musl static build.
RUN JJ_URL="$(curl -fsSL https://api.github.com/repos/jj-vcs/jj/releases/latest \
        | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url' \
        | head -n1)" \
    && curl -fsSL "$JJ_URL" -o /tmp/jj.tgz \
    && tar -xzf /tmp/jj.tgz -C /usr/local/bin jj \
    && chmod +x /usr/local/bin/jj \
    && rm -f /tmp/jj.tgz

# stylua — latest release standalone binary (formatter fallback, DESIGN §9).
RUN STYLUA_URL="$(curl -fsSL https://api.github.com/repos/JohnnyMorganz/StyLua/releases/latest \
        | jq -r '.assets[] | select(.name | test("linux-x86_64.zip$")) | .browser_download_url' \
        | head -n1)" \
    && curl -fsSL "$STYLUA_URL" -o /tmp/stylua.zip \
    && unzip -o /tmp/stylua.zip stylua -d /usr/local/bin \
    && chmod +x /usr/local/bin/stylua \
    && rm -f /tmp/stylua.zip

# fnm (node version manager) binary on PATH; node versions live in a volume (§7).
RUN curl -fsSL https://fnm.vercel.app/install \
        | bash -s -- --install-dir /usr/local/bin --skip-shell

# ---------------------------------------------------------------------------
# 2. .NET SDK (DESIGN §5 step 3) — .NET 10 only.
# ---------------------------------------------------------------------------
ENV DOTNET_ROOT=/opt/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir /opt/dotnet \
    && rm -f /tmp/dotnet-install.sh
ENV PATH=/opt/dotnet:/opt/dotnet-tools:/opt/cage/bin:/usr/local/bin:$PATH

# csharpier as a baked global tool (formatter fallback, DESIGN §9). Lives in a
# plain image path (not a volume) so the daily rebuild owns its version.
RUN dotnet tool install --tool-path /opt/dotnet-tools csharpier

# ---------------------------------------------------------------------------
# 3. User + writable mountpoints
# ---------------------------------------------------------------------------
# uid/gid 1000 mirror the host so --userns=keep-id yields correct file ownership
# in ~/code and identical $PWD resolution (DESIGN §6).
RUN groupadd -g 1000 mnj \
    && useradd -m -u 1000 -g 1000 -s /bin/bash mnj \
    # Volume mountpoints owned by mnj so podman's copy-up preserves correct
    # ownership and runtime writes (new node versions, npm -g) succeed.
    && mkdir -p /opt/fnm /opt/cage \
        /home/mnj/.local/bin \
        /home/mnj/.npm \
        /home/mnj/.nuget/packages \
        /home/mnj/.local/state/nvim \
    && chown -R mnj:mnj /opt/fnm /opt/cage /home/mnj

# ---------------------------------------------------------------------------
# 4. Shell environment (PATH, fnm, dotnet) — DESIGN §6/§9.
# ---------------------------------------------------------------------------
# Sourced by login/interactive shells via /etc/profile.d and by Claude's
# non-interactive Bash tool via BASH_ENV. Mason bin is first on PATH so the cage
# uses the exact host formatter binaries; baked formatters are the fallback.
COPY --chown=root:root etc/cage-env.sh /etc/cage/env.sh
RUN ln -sf /etc/cage/env.sh /etc/profile.d/cage.sh

ENV FNM_DIR=/opt/fnm \
    NPM_CONFIG_PREFIX=/opt/cage \
    TZ=Europe/Warsaw \
    DISABLE_AUTOUPDATER=1

# ---------------------------------------------------------------------------
# 5. Per-user toolchains (node + node-based formatters + Claude Code)
# ---------------------------------------------------------------------------
USER mnj
WORKDIR /home/mnj

# Latest LTS node as the default; per-project versions added on demand into the
# fnm volume at runtime (DESIGN §5 step 4). Baked LTS reaches the fresh volume
# via podman's first-mount copy-up.
RUN eval "$(fnm env --shell bash)" \
    && fnm install --lts \
    && fnm default "$(fnm current)"

# prettier + eslint fallbacks into the cage global prefix (DESIGN §5 step 5/§9).
RUN eval "$(fnm env --shell bash)" \
    && npm install -g prettier eslint

# Claude Code — latest, via the native installer (standalone binary, no node
# coupling). Installed under ~/.local/bin (image layer, not a volume) so the
# image owns the version; DISABLE_AUTOUPDATER keeps it from drifting in-session.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && /home/mnj/.local/bin/claude --version > /home/mnj/.cage-claude-version 2>/dev/null || true

# ---------------------------------------------------------------------------
# --- extra toolchains (add here) -------------------------------------------
# To add a language (Rust, Python, Go, …), append ONE self-contained RUN per
# language below. Keep all toolchain installs in this block so the single edit
# is obvious and the daily rebuild picks it up (DESIGN §5 "extensibility").
#
#   # Rust
#   RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
#
# ---------------------------------------------------------------------------

# BASH_ENV is set last so it doesn't perturb the build RUNs above; from here on
# every non-interactive bash (Claude's Bash tool, hooks) sources the cage env.
ENV BASH_ENV=/etc/cage/env.sh

LABEL org.opencontainers.image.title="agent-cage" \
      org.opencontainers.image.description="Sandbox image for running Claude Code with --dangerously-skip-permissions" \
      org.opencontainers.image.source="https://github.com/marcinjahn/agent-cage"

CMD ["claude", "--dangerously-skip-permissions"]
