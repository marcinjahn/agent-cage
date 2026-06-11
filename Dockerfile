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
# compile anything not already prebuilt in the mounted data dir. libicu is
# required by the .NET SDK (§2) for globalization — without it dotnet crashes.
# The network tools (iputils=ping, bind-utils=dig/nslookup/host, iproute=ip/ss,
# traceroute, mtr, nmap, nmap-ncat=nc, tcpdump, socat, whois, net-tools,
# bind-utils, wget, telnet, lsof) cover typical connectivity/DNS debugging.
RUN dnf -y install \
        bash ca-certificates curl tar xz unzip findutils which procps-ng tree \
        git jq \
        libicu \
        neovim libnotify \
        gcc gcc-c++ make \
        fuse-overlayfs \
        iputils iproute traceroute mtr bind-utils \
        nmap nmap-ncat tcpdump socat whois net-tools wget telnet lsof \
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

# acli (Atlassian CLI) — per Atlassian's Linux instructions (single static binary).
RUN curl -fsSL "https://acli.atlassian.com/linux/latest/acli_linux_amd64/acli" \
        -o /usr/local/bin/acli \
    && chmod +x /usr/local/bin/acli

# jj (jujutsu) — latest release, musl static build.
RUN JJ_URL="$(curl -fsSL https://api.github.com/repos/jj-vcs/jj/releases/latest \
        | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url' \
        | head -n1)" \
    && curl -fsSL "$JJ_URL" -o /tmp/jj.tgz \
    && tar -xzf /tmp/jj.tgz -C /usr/local/bin --strip-components=1 ./jj \
    && chmod +x /usr/local/bin/jj \
    && rm -f /tmp/jj.tgz

# just (command runner) — latest release, musl static build.
RUN JUST_URL="$(curl -fsSL https://api.github.com/repos/casey/just/releases/latest \
        | jq -r '.assets[] | select(.name | test("x86_64-unknown-linux-musl.tar.gz$")) | .browser_download_url' \
        | head -n1)" \
    && curl -fsSL "$JUST_URL" -o /tmp/just.tgz \
    && tar -xzf /tmp/just.tgz -C /usr/local/bin just \
    && chmod +x /usr/local/bin/just \
    && rm -f /tmp/just.tgz

# yq (mikefarah, the Go YAML/JSON processor) — latest release, single static binary.
RUN YQ_URL="$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest \
        | jq -r '.assets[] | select(.name == "yq_linux_amd64") | .browser_download_url' \
        | head -n1)" \
    && curl -fsSL "$YQ_URL" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

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
# ~/.local/bin holds the native-installed Claude binary; it must be on the ENV
# PATH (not just cage-env.sh) so the exec-form CMD, which runs without a shell
# and never sources BASH_ENV, can resolve `claude`. ~/scripts is here for the
# same reason: claude inherits this PATH and passes it to subprocesses it spawns
# directly (e.g. tools invoking `limited`), which likewise bypass BASH_ENV.
ENV PATH=/home/mnj/.local/bin:/home/mnj/.cargo/bin:/opt/dotnet:/opt/dotnet-tools:/opt/copilot/bin:/opt/ctx7/bin:/opt/pnpm/bin:/opt/playwright/bin:/opt/cage/bin:/home/mnj/scripts:/usr/local/bin:$PATH

# csharpier as a baked global tool (formatter fallback, DESIGN §9). Lives in a
# plain image path (not a volume) so the daily rebuild owns its version.
RUN dotnet tool install --tool-path /opt/dotnet-tools csharpier

# csharp-ls — C# LSP server used by claude's LSP plugin. Same baked-tool path.
RUN dotnet tool install --tool-path /opt/dotnet-tools csharp-ls

# ---------------------------------------------------------------------------
# 3. User + writable mountpoints
# ---------------------------------------------------------------------------
# uid/gid 1000 mirror the host so --userns=keep-id yields correct file ownership
# in ~/code and identical $PWD resolution (DESIGN §6).
RUN groupadd -g 1000 mnj \
    && useradd -m -u 1000 -g 1000 -s /bin/bash mnj \
    # Volume mountpoints owned by mnj so podman's copy-up preserves correct
    # ownership and runtime writes (new node versions, npm -g) succeed.
    && mkdir -p /opt/fnm /opt/cage /opt/copilot /opt/ctx7 /opt/pnpm /opt/playwright \
        /home/mnj/.local/bin \
        /home/mnj/.npm \
        /home/mnj/.nuget/packages \
        /home/mnj/.local/state/nvim \
    && chown -R mnj:mnj /opt/fnm /opt/cage /opt/copilot /opt/ctx7 /opt/pnpm /opt/playwright /home/mnj

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
    DISABLE_AUTOUPDATER=1 \
    COPILOT_AUTO_UPDATE=false \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright/browsers

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

# typescript-language-server (+ typescript) — JS/TS LSP server for claude's LSP
# plugin. Installed into the cage global prefix; expects both binaries on PATH.
RUN eval "$(fnm env --shell bash)" \
    && npm install -g typescript-language-server typescript

# Claude Code — latest, via the native installer (standalone binary, no node
# coupling). Installed under ~/.local/bin (image layer, not a volume) so the
# image owns the version; DISABLE_AUTOUPDATER keeps it from drifting in-session.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && /home/mnj/.local/bin/claude --version > /home/mnj/.cage-claude-version 2>/dev/null || true

# GitHub Copilot CLI — latest, into a dedicated /opt/copilot prefix (image layer,
# NOT the /opt/cage volume) so the daily rebuild owns the version; --prefix
# overrides NPM_CONFIG_PREFIX for this one install. The first `copilot` run is
# triggered here so its npm-loader bakes the platform binary into ~/.copilot/pkg
# (an image layer, since ~/.copilot is not a mount) instead of downloading it on
# first use. Auth is NOT baked: the wrapper forwards the host GitHub token as
# GH_TOKEN at runtime (DESIGN §7).
RUN eval "$(fnm env --shell bash)" \
    && npm install -g --prefix /opt/copilot @github/copilot \
    && /opt/copilot/bin/copilot --version > /home/mnj/.cage-copilot-version 2>/dev/null || true

# Context7 CLI (ctx7) — up-to-date library docs for the agents. Latest, into a
# dedicated /opt/ctx7 prefix (image layer, NOT the /opt/cage volume) so the daily
# rebuild owns the version. Auth is NOT baked: the wrapper bind-mounts the host
# ~/.context7/credentials.json read-only at runtime (DESIGN §7).
RUN eval "$(fnm env --shell bash)" \
    && npm install -g --prefix /opt/ctx7 ctx7 \
    && /opt/ctx7/bin/ctx7 --version > /home/mnj/.cage-ctx7-version 2>/dev/null || true

# pnpm package manager — latest, into a dedicated /opt/pnpm prefix (image layer,
# NOT the /opt/cage volume) so the daily rebuild owns the version. No auth to
# bake; the content-addressable store is bind-mounted from the host at runtime
# (shared with the host store, on the same fs as ~/code so hardlinks work — see
# _cage-lib.sh / DESIGN §7).
RUN eval "$(fnm env --shell bash)" \
    && npm install -g --prefix /opt/pnpm pnpm \
    && /opt/pnpm/bin/pnpm --version > /home/mnj/.cage-pnpm-version 2>/dev/null || true

# ---------------------------------------------------------------------------
# --- extra toolchains (add here) -------------------------------------------
# To add a language (Rust, Python, Go, …), append ONE self-contained RUN per
# language below. Keep all toolchain installs in this block so the single edit
# is obvious and the daily rebuild picks it up (DESIGN §5 "extensibility").
# ---------------------------------------------------------------------------

# Rust — rustup with the default profile (tracks latest stable), so rustc, cargo
# and the rustfmt formatter (DESIGN §9 fallback) come in one shot. The
# rust-analyzer LSP server (for claude's LSP plugin) is added as a rustup
# component. CARGO_HOME/RUSTUP_HOME default to ~/.cargo and ~/.rustup, which are
# image layers (no volume covers them) so the daily rebuild owns the version;
# ~/.cargo/bin is added to PATH (ENV above + cage-env.sh). --no-modify-path keeps
# rustup from editing shell profiles, since PATH is managed centrally.
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
        | sh -s -- -y --profile default --no-modify-path \
    && /home/mnj/.cargo/bin/rustup component add rust-analyzer \
    && /home/mnj/.cargo/bin/rustc --version > /home/mnj/.cage-rust-version 2>/dev/null || true

# Python — interpreter + pip from Fedora's repo (tracks latest 3.x). dnf needs
# root, so this drops back to USER root and restores USER mnj afterwards.
USER root
RUN dnf -y install python3 python3-pip \
    && dnf clean all
USER mnj

# Ruby — interpreter + rubygems from Fedora's repo (tracks latest 3.x). Same
# root dance as Python since dnf needs root.
USER root
RUN dnf -y install ruby rubygems \
    && dnf clean all
USER mnj

# Playwright CLI (@playwright/cli) + Chromium/Firefox browsers, for the
# playwright-cli skill (browser automation). Browser OS libraries come from
# Fedora's repos: Playwright's own `install-deps` only supports Debian/Ubuntu,
# so the Chromium+Firefox shared-lib set is listed explicitly (every name was
# validated against Fedora 43). --skip-unavailable keeps the daily rebuild green
# if Fedora ever renames one. WebKit is intentionally omitted — its libwpe /
# wpebackend-fdo aren't packaged for Fedora. dnf needs root, hence the dance.
USER root
RUN dnf -y install --skip-unavailable \
        alsa-lib at-spi2-atk at-spi2-core atk cairo cairo-gobject cups-libs \
        dbus-libs dbus-glib expat glib2 gtk3 gdk-pixbuf2 \
        libX11 libXcomposite libXdamage libXext libXfixes libXrandr libXtst \
        libXScrnSaver libXt libdrm libgcc libxcb libxkbcommon libxshmfence \
        mesa-libgbm mesa-libEGL nspr nss pango \
    && dnf clean all
USER mnj

# CLI into a dedicated /opt/playwright prefix (image layer, NOT the /opt/cage
# volume) so the daily rebuild owns the version. The browser binaries are baked
# into a fixed PLAYWRIGHT_BROWSERS_PATH (also an image layer — no volume covers
# ~/.cache) and resolved there at runtime via the same env var. Browser install
# is driven through the bundled playwright-core (a dep of @playwright/cli), not
# `playwright-cli install` (which only scaffolds skills). A global install nests
# playwright-core under @playwright/cli and its package `exports` hide cli.js, so
# the entrypoint is located by path rather than module resolution.
#
# The extraction runs under a throwaway Node 22 (temp FNM_DIR, deleted after) to
# dodge a yauzl regression that hangs browser-archive extraction at "100%" on
# Node 24.16.0+ / 26.x (microsoft/playwright#40724). @playwright/cli pins a stale
# playwright-core alpha that predates the fix (shipped in 1.60.0), and bumping it
# isn't an option — its chromium revision must match the runtime CLI's. Pinning
# an unaffected Node for the install sidesteps the bug without touching versions.
# Runtime browser launches don't extract archives, so the default LTS is fine.
RUN export FNM_DIR=/tmp/fnm-pw \
    && eval "$(fnm env --shell bash)" \
    && fnm install 22 \
    && fnm use 22 \
    && npm install -g --prefix /opt/playwright @playwright/cli \
    && node "$(find /opt/playwright/lib/node_modules -path '*playwright-core/cli.js' | head -n1)" install chromium firefox \
    && { /opt/playwright/bin/playwright-cli --version > /home/mnj/.cage-playwright-version 2>/dev/null || true; } \
    && rm -rf /tmp/fnm-pw

# BASH_ENV is set last so it doesn't perturb the build RUNs above; from here on
# every non-interactive bash (Claude's Bash tool, hooks) sources the cage env.
ENV BASH_ENV=/etc/cage/env.sh

LABEL org.opencontainers.image.title="agent-cage" \
      org.opencontainers.image.description="Sandbox image for running Claude Code with --dangerously-skip-permissions" \
      org.opencontainers.image.source="https://github.com/marcinjahn/agent-cage"

CMD ["claude", "--dangerously-skip-permissions"]
