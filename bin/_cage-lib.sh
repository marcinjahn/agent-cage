#!/usr/bin/env bash
# Shared configuration and helpers for the agent-cage wrappers (DESIGN §6-§8).
# Sourced by `claude-cage` and `cage`; not meant to be executed directly.

# --- configuration (override via environment) --------------------------------
CAGE_IMAGE="${CAGE_IMAGE:-ghcr.io/marcinjahn/agent-cage:latest}"
CAGE_SIDECAR_IMAGE="${CAGE_SIDECAR_IMAGE:-docker.io/library/docker:dind-rootless}"

# Per-session resource caps (DESIGN §3 — favors many parallel sessions).
CAGE_MEMORY="${CAGE_MEMORY:-4g}"
CAGE_CPUS="${CAGE_CPUS:-2}"

# Lazy pull: refresh :latest at most once per this many seconds (default 24h),
# so launches stay fast (DESIGN §5/§13).
CAGE_PULL_INTERVAL="${CAGE_PULL_INTERVAL:-86400}"

# Optional sidecar storage driver override ("vfs" if fuse-overlayfs is
# unavailable on the host — DESIGN §8).
CAGE_SIDECAR_STORAGE="${CAGE_SIDECAR_STORAGE:-}"

# Sidecar container + shared volume names.
CAGE_SIDECAR_NAME="agent-cage-docker"
CAGE_VOL_SOCK="agent-cage-sock"
CAGE_VOL_DOCKER_DATA="agent-cage-docker-data"
CAGE_VOL_FNM="agent-cage-fnm"
CAGE_VOL_NPM="agent-cage-npm"
CAGE_VOL_GLOBAL="agent-cage-global"
CAGE_VOL_NVIM_STATE="agent-cage-nvim-state"

# Container-side fixed paths (single-user; uid 1000 / home /home/mnj).
CAGE_HOME="/home/mnj"
CAGE_SOCK="/sock/docker.sock"

CAGE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-cage"

# Repo-relative assets (the sidecar's subordinate-id map — DESIGN §8).
CAGE_ETC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../etc" && pwd)"

cage_err() { printf 'agent-cage: %s\n' "$*" >&2; }
cage_die() {
  cage_err "$*"
  exit 1
}

# --- image pull (rate-limited) ------------------------------------------------
cage_lazy_pull() {
  local stamp="$CAGE_STATE_DIR/last-pull" now last=0
  mkdir -p "$CAGE_STATE_DIR"
  now="$(date +%s)"

  if ! podman image exists "$CAGE_IMAGE"; then
    cage_err "pulling $CAGE_IMAGE (first run)…"
    podman pull "$CAGE_IMAGE" ||
      cage_die "failed to pull $CAGE_IMAGE — if the package is private, run: podman login ghcr.io"
    echo "$now" >"$stamp"
    return 0
  fi

  [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
  if [ $((now - last)) -ge "$CAGE_PULL_INTERVAL" ]; then
    cage_err "checking for a newer $CAGE_IMAGE…"
    podman pull "$CAGE_IMAGE" >/dev/null 2>&1 || cage_err "pull failed; using cached image"
    echo "$now" >"$stamp"
  fi
}

# --- run-argument assembly ----------------------------------------------------
# Populates the global RUN_ARGS array with all flags, mounts and envs shared by
# `claude-cage` and the `cage` shell.
cage_build_run_args() {
  RUN_ARGS=(
    --rm
    --userns=keep-id             # host uid 1000 <-> container uid 1000 (DESIGN §6)
    --network host               # bidirectional port-forwarding (DESIGN §10)
    --security-opt label=disable # do NOT relabel ~/code (~75 GB); DESIGN §7
    --memory="$CAGE_MEMORY"
    --cpus="$CAGE_CPUS"
    -w "$PWD" # start Claude in the same dir -> shared session encoding
  )
  _cage_add_mounts
  _cage_add_envs
}

# Append a bind mount, skipping (with a warning) anything missing on the host.
_cage_bind() {
  local mode="$1" src="$2" dst="$3"
  if [ ! -e "$src" ]; then
    cage_err "skipping missing mount: $src"
    return 0
  fi
  RUN_ARGS+=(-v "$src:$dst:$mode")
}

_cage_add_mounts() {
  # Named volumes — persist across sessions and image rebuilds (DESIGN §7).
  RUN_ARGS+=(
    -v "$CAGE_VOL_FNM:/opt/fnm"
    -v "$CAGE_VOL_GLOBAL:/opt/cage"
    -v "$CAGE_VOL_NPM:$CAGE_HOME/.npm"
    -v "$CAGE_VOL_NVIM_STATE:$CAGE_HOME/.local/state/nvim"
    -v "$CAGE_VOL_SOCK:/sock"
  )

  # Share the host nuget restore cache (rw) so builds reuse already-downloaded
  # packages instead of re-pulling into an empty volume. uid 1000 maps through
  # --userns=keep-id so writes land back in the host cache with correct
  # ownership; label=disable avoids relabeling the (large) cache dir.
  _cage_bind rw "$HOME/.nuget/packages" "$CAGE_HOME/.nuget/packages"

  # The work + agent state (rw).
  _cage_bind rw "$HOME/code" "$CAGE_HOME/code"
  _cage_bind rw "$HOME/.claude" "$CAGE_HOME/.claude"
  _cage_bind rw "$HOME/.claude.json" "$CAGE_HOME/.claude.json"

  # Host-executed scripts within ~/.claude, overlaid read-only so an injected
  # prompt cannot plant code that later runs on the host as you (DESIGN §2/§7).
  _cage_bind ro "$HOME/.claude/hooks" "$CAGE_HOME/.claude/hooks"
  _cage_bind ro "$HOME/.claude/settings.json" "$CAGE_HOME/.claude/settings.json"
  _cage_bind ro "$HOME/.claude/settings.local.json" "$CAGE_HOME/.claude/settings.local.json"
  _cage_bind ro "$HOME/.claude/statusline-command.sh" "$CAGE_HOME/.claude/statusline-command.sh"

  # VCS identity (ro) so commits carry the right author; no SSH keys (DESIGN §7).
  _cage_bind ro "$HOME/.gitconfig" "$CAGE_HOME/.gitconfig"
  _cage_bind ro "$HOME/.config/jj/config.toml" "$CAGE_HOME/.config/jj/config.toml"

  # Skills' scripts (on PATH) + puff symlink target (resolves ~/code symlinks).
  _cage_bind ro "$HOME/scripts" "$CAGE_HOME/scripts"
  _cage_bind ro "$HOME/.local/share/puff/projects" "$CAGE_HOME/.local/share/puff/projects"

  # nvim config + data (ro) for the formatting hook (DESIGN §9). State is a volume.
  _cage_bind ro "$HOME/.config/nvim" "$CAGE_HOME/.config/nvim"
  _cage_bind ro "$HOME/.local/share/nvim" "$CAGE_HOME/.local/share/nvim"

  # Credentials — mount config FILES (not dirs) for tools that also write caches,
  # so caches land in container-private paths and the tool still works (DESIGN §7).
  _cage_bind ro "$HOME/.kube/config" "$CAGE_HOME/.kube/config"
  _cage_bind ro "$HOME/.docker/config.json" "$CAGE_HOME/.docker/config.json"
  _cage_bind ro "$HOME/.npmrc" "$CAGE_HOME/.npmrc"
  _cage_bind ro "$HOME/.config/NuGet" "$CAGE_HOME/.config/NuGet"
  _cage_bind ro "$HOME/.config/acli" "$CAGE_HOME/.config/acli"
  _cage_bind ro "$HOME/.config/gh" "$CAGE_HOME/.config/gh"

  # Notifications via the host session bus (DESIGN §9).
  _cage_bind ro "/run/user/1000/bus" "/run/user/1000/bus"
}

_cage_add_envs() {
  RUN_ARGS+=(
    --env AGENT_CAGE=1                    # cage marker (DESIGN §11)
    --env "DOCKER_HOST=unix://$CAGE_SOCK" # -> the sidecar (DESIGN §8)
    --env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    --env "XDG_RUNTIME_DIR=/run/user/1000"
    --env "TZ=Europe/Warsaw"
    --env "DISABLE_AUTOUPDATER=1"
  )
  # GitHub token for the Copilot CLI and `gh` inside the cage. The host keeps it in
  # the OS keyring (not a file), so it can't be bind-mounted like other creds; we
  # read it out with `gh auth token` and forward it as GH_TOKEN, which both Copilot
  # and gh honor (DESIGN §7). Passed by name (value via the wrapper's own env) so it
  # never lands in podman's argv. Skipped silently if gh is absent/logged out.
  local gh_token
  if gh_token="$(gh auth token 2>/dev/null)" && [ -n "$gh_token" ]; then
    export GH_TOKEN="$gh_token"
    RUN_ARGS+=(--env GH_TOKEN)
  fi

  # Forward any CLAUDE_* set on the host (CLAUDE_NO_FORMAT, CLAUDE_BYPASS_BUILD_SUMMARY, …).
  local name
  for name in $(env | grep -oE '^CLAUDE_[A-Za-z0-9_]+' || true); do
    RUN_ARGS+=(--env "$name")
  done
}

# --- docker sidecar lifecycle (DESIGN §8) -------------------------------------
cage_sidecar_healthy() {
  podman exec "$CAGE_SIDECAR_NAME" docker info >/dev/null 2>&1
}

cage_sidecar_start() {
  cage_err "starting docker sidecar ($CAGE_SIDECAR_NAME)…"
  local extra=()
  [ -n "$CAGE_SIDECAR_STORAGE" ] && extra+=("--storage-driver=$CAGE_SIDECAR_STORAGE")

  # Rootless dind under rootless Podman (DESIGN §8). Mounts ONLY ~/code so a
  # docker bind-mount escape is bounded to the same surface as the cage.
  #
  # --privileged is REQUIRED here and, under ROOTLESS Podman, does NOT grant
  # root-on-host: the container still runs entirely within the user's namespace
  # (uid 1000 + the unprivileged subuid block). It only lifts the masked-path
  # and dropped-capability restrictions so the *nested* dockerd can mount fresh
  # /proc and /sys for the containers it launches — without it, container starts
  # fail with `mounting "proc"/"sysfs" ... operation not permitted`. (This is the
  # standard way the official docker:dind-rootless image is run.)
  #
  # --userns=keep-id aligns the daemon's socket owner with the host uid so cage
  # sessions can use it; but it maps only the host's single 65536-id subuid block
  # into the container, so the image's stock rootless:100000:65536 map is out of
  # range and rootlesskit's newuidmap fails. We mount a fitted subid map instead.
  podman run -d --name "$CAGE_SIDECAR_NAME" \
    --privileged \
    --userns=keep-id \
    --network host \
    --security-opt label=disable \
    --stop-timeout 30 \
    -e "DOCKER_HOST=unix://$CAGE_SOCK" \
    -v "$CAGE_ETC/sidecar-subid:/etc/subuid:ro" \
    -v "$CAGE_ETC/sidecar-subid:/etc/subgid:ro" \
    -v "$CAGE_VOL_SOCK:/sock:U" \
    -v "$CAGE_VOL_DOCKER_DATA:/home/rootless/.local/share/docker" \
    -v "$HOME/code:$HOME/code:rw" \
    "$CAGE_SIDECAR_IMAGE" \
    --host="unix://$CAGE_SOCK" "${extra[@]}" \
    >/dev/null ||
    cage_die "failed to start docker sidecar"

  local _
  for _ in $(seq 1 30); do
    cage_sidecar_healthy && return 0
    sleep 1
  done
  cage_err "docker sidecar did not become healthy in 30s; inspect with 'cage docker status'"
  return 1
}

cage_sidecar_ensure() {
  if podman container exists "$CAGE_SIDECAR_NAME"; then
    if [ "$(podman inspect -f '{{.State.Running}}' "$CAGE_SIDECAR_NAME" 2>/dev/null)" = "true" ] &&
      cage_sidecar_healthy; then
      return 0
    fi
    cage_err "docker sidecar present but unhealthy; recreating…"
    podman rm -f "$CAGE_SIDECAR_NAME" >/dev/null 2>&1 || true
  fi
  cage_sidecar_start
}

cage_sidecar_status() {
  if ! podman container exists "$CAGE_SIDECAR_NAME"; then
    echo "docker sidecar: not created"
    return 0
  fi
  podman ps -a --filter "name=^${CAGE_SIDECAR_NAME}$" \
    --format 'docker sidecar: {{.Names}} [{{.Status}}]'
  if cage_sidecar_healthy; then
    echo "daemon: healthy ($CAGE_SOCK)"
    podman exec "$CAGE_SIDECAR_NAME" docker version --format \
      'client: {{.Client.Version}}  server: {{.Server.Version}}' 2>/dev/null || true
  else
    echo "daemon: NOT responding"
  fi
}

cage_sidecar_stop() {
  if podman rm -f "$CAGE_SIDECAR_NAME" >/dev/null 2>&1; then
    cage_err "docker sidecar stopped"
  else
    cage_err "docker sidecar was not running"
  fi
}

cage_sidecar_reset() {
  cage_sidecar_stop
  podman volume rm -f "$CAGE_VOL_DOCKER_DATA" "$CAGE_VOL_SOCK" >/dev/null 2>&1 || true
  cage_err "docker sidecar data + socket volumes removed"
  cage_sidecar_ensure
}
