#!/usr/bin/env bash
# Shared configuration and helpers for the agent-cage wrappers (DESIGN §6-§8).
# Sourced by `claude-cage` and `cage`; not meant to be executed directly.

# --- configuration (override via environment) --------------------------------
CAGE_IMAGE="${CAGE_IMAGE:-ghcr.io/marcinjahn/agent-cage:latest}"
CAGE_SIDECAR_IMAGE="${CAGE_SIDECAR_IMAGE:-docker.io/library/docker:dind-rootless}"

# Per-session resource caps (DESIGN §3 — favors many parallel sessions).
CAGE_MEMORY="${CAGE_MEMORY:-4g}"
CAGE_CPUS="${CAGE_CPUS:-2}"

# Lazy pull: refresh :latest at most once per this many seconds. Default is once
# a day so day-to-day launches are fast and don't hit the registry; the image is
# rebuilt daily, so a daily check keeps :latest current without per-launch cost.
# An unchanged :latest only costs a cheap digest check, and an unreachable
# registry falls back to the cached image (DESIGN §5/§13). Set to 0 to check on
# every launch, or pass --update / set CAGE_FORCE_PULL=1 to force a check now.
CAGE_PULL_INTERVAL="${CAGE_PULL_INTERVAL:-86400}"

# When 1, cage_lazy_pull checks the registry regardless of CAGE_PULL_INTERVAL.
# Set by the wrappers' --update flag for an on-demand refresh.
CAGE_FORCE_PULL="${CAGE_FORCE_PULL:-0}"

# When 1, cage_lazy_pull never contacts the registry — it uses the locally cached
# image as-is (only a missing image is still pulled, since there's nothing to run
# otherwise). Set by the wrappers' --no-update flag; handy on a slow connection.
# Takes precedence over CAGE_FORCE_PULL.
CAGE_NO_PULL="${CAGE_NO_PULL:-0}"

# When 1, also bind-mount the current dir into the cage (at the same host path) so
# a session can run from a dir OUTSIDE the configured work roots below. Set by the
# wrappers' --mount-cwd flag. Without it, claude-cage refuses to launch from
# outside the roots (the dir wouldn't be mounted and Claude would see nothing).
CAGE_MOUNT_CWD="${CAGE_MOUNT_CWD:-0}"

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

# Name the wrapper was invoked as (claude-cage / cage), for use in messages.
CAGE_INVOKED_AS="${CAGE_INVOKED_AS:-$(basename "$0")}"

# Host dirs that are bind-mounted rw at the same path inside the cage, so the cwd
# can live under any of them (-w "$PWD" resolves). claude-cage refuses to launch
# from outside these — otherwise podman would create an empty workdir and Claude
# would see none of your files. Keep in sync with the rw work binds in
# _cage_add_mounts.
CAGE_WORK_ROOTS=("$HOME/code" "$HOME/triage-issues")

# Repo-relative assets (the sidecar's subordinate-id map — DESIGN §8).
CAGE_ETC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../etc" && pwd)"

cage_err() { printf 'agent-cage: %s\n' "$*" >&2; }
cage_die() {
  cage_err "$*"
  exit 1
}

# True (0) when $1 is at or under one of the rw work roots.
_cage_under_work_root() {
  local dir="$1" root
  for root in "${CAGE_WORK_ROOTS[@]}"; do
    case "$dir/" in "$root/"*) return 0 ;; esac
  done
  return 1
}

# Die unless the cwd is under one of the rw work roots (so -w "$PWD" resolves to a
# real, mounted dir inside the cage rather than an empty one). --mount-cwd
# (CAGE_MOUNT_CWD=1) waives this by binding the cwd in on the fly (see
# _cage_add_mounts), so an outside dir is allowed once the user opts in.
cage_require_workdir() {
  _cage_under_work_root "$PWD" && return 0
  [ "$CAGE_MOUNT_CWD" = "1" ] && return 0

  cage_err "refusing to run from $PWD"
  cage_err "  it's outside the cage's work roots (${CAGE_WORK_ROOTS[*]}), so it"
  cage_err "  wouldn't be mounted and Claude would see an empty directory."
  cage_err ""
  cage_err "  To mount the current directory into the cage anyway, add --mount-cwd:"
  cage_err "      ${CAGE_INVOKED_AS:-claude-cage} --mount-cwd …"
  exit 1
}

# --- image pull (rate-limited) ------------------------------------------------
# True (0) when the registry holds a digest that differs from the local image —
# i.e. a pull would actually download a new image. Uses skopeo for a cheap,
# download-free comparison; if skopeo is missing or the check is inconclusive we
# return 0 so the caller still pulls (never silently run a stale image).
cage_image_outdated() {
  if ! command -v skopeo >/dev/null 2>&1; then
    cage_err "skopeo not installed — can't check the registry cheaply; pulling unconditionally (install skopeo to skip unchanged images)"
    return 0
  fi

  local remote local_digests
  remote="$(skopeo inspect --format '{{ .Digest }}' "docker://$CAGE_IMAGE" 2>/dev/null)" || return 0
  [ -n "$remote" ] || return 0

  # The local image may be known by its manifest digest and/or one or more repo
  # digests; a match against any of them means we already have what's served.
  local_digests="$(podman image inspect \
    --format '{{ .Digest }} {{ range .RepoDigests }}{{ . }} {{ end }}' \
    "$CAGE_IMAGE" 2>/dev/null)" || return 0

  case "$local_digests" in
  *"$remote"*) return 1 ;; # up to date
  *) return 0 ;;           # newer image available
  esac
}

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

  # Stay offline: run whatever image we already have, skipping the registry check.
  [ "$CAGE_NO_PULL" = "1" ] && return 0

  [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
  if [ "$CAGE_FORCE_PULL" = "1" ] || [ $((now - last)) -ge "$CAGE_PULL_INTERVAL" ]; then
    cage_err "checking for a newer $CAGE_IMAGE…"
    if cage_image_outdated; then
      cage_err "newer image available — downloading…"
      # Let podman's pull progress reach the terminal (stdout -> stderr, keeping
      # our stdout clean) so a download isn't a silent stall. Unchanged images
      # stay quiet because the digest check above skips the pull entirely.
      podman pull "$CAGE_IMAGE" >&2 || cage_err "pull failed; using cached image"
    fi
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

# Produce the docker config.json to mount, echoing its host path.
#
# The host config delegates GCR / Artifact Registry hosts to the `gcloud`
# credential helper, which can't run in the cage: gcloud isn't installed and its
# refresh token is a long-lived secret we deliberately don't mount (DESIGN §2).
# So, mirroring GH_TOKEN (§7), mint a short-lived OAuth access token on the host
# (where gcloud is authenticated) and bake it into a generated config as a static
# `auths` entry for every gcloud-helper host, dropping those credHelpers so docker
# inside the cage doesn't look for the absent helper. testcontainers reads this to
# pull private images. The token expires in ~1h, but the sidecar caches the image
# after the first pull, so a launch-time token is enough in practice.
# Falls back to the host config untouched when gcloud/jq/token aren't available.
_cage_docker_config() {
  local host_cfg="$HOME/.docker/config.json" tok base gen="$CAGE_STATE_DIR/docker-config.json"

  if ! command -v gcloud >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 ||
    ! tok="$(gcloud auth print-access-token 2>/dev/null)" || [ -z "$tok" ]; then
    printf '%s' "$host_cfg"
    return 0
  fi

  base="$(cat "$host_cfg" 2>/dev/null)"
  [ -n "$base" ] || base='{}'
  mkdir -p "$CAGE_STATE_DIR"

  if printf '%s' "$base" | jq \
    --arg auth "$(printf 'oauth2accesstoken:%s' "$tok" | base64 -w0)" '
      (.credHelpers // {}) as $h
      | .auths = ((.auths // {}) + ($h
          | to_entries | map(select(.value == "gcloud")
          | {key: .key, value: {auth: $auth}}) | from_entries))
      | .credHelpers = ($h | with_entries(select(.value != "gcloud")))
    ' >"$gen" 2>/dev/null; then
    chmod 600 "$gen"
    printf '%s' "$gen"
  else
    printf '%s' "$host_cfg"
  fi
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

  # Share the host pnpm store + metadata cache (rw), like nuget above. pnpm
  # hardlinks packages from its content-addressable store into each project's
  # node_modules, which requires the store to be on the SAME filesystem as the
  # project — both these and ~/code are host binds on /home, so the links resolve
  # (a named volume under podman's graphroot would be a different mount and force
  # slow full copies instead). Container pnpm uses the default XDG paths, which
  # equal these, so no PNPM_HOME / store-dir config is needed. Only the `store/`
  # is shared (not all of ~/.local/share/pnpm), keeping the cage's own pnpm global
  # state container-local. mkdir so a fresh host still gets a persistent store.
  mkdir -p "$HOME/.local/share/pnpm/store" "$HOME/.cache/pnpm" 2>/dev/null || true
  _cage_bind rw "$HOME/.local/share/pnpm/store" "$CAGE_HOME/.local/share/pnpm/store"
  _cage_bind rw "$HOME/.cache/pnpm" "$CAGE_HOME/.cache/pnpm"

  # The work + agent state (rw).
  _cage_bind rw "$HOME/code" "$CAGE_HOME/code"
  _cage_bind rw "$HOME/.claude" "$CAGE_HOME/.claude"
  _cage_bind rw "$HOME/.claude.json" "$CAGE_HOME/.claude.json"

  # --mount-cwd: bind the current dir at the same host path so a session can run
  # from outside the work roots above (-w "$PWD" then resolves to real files).
  # Skipped when the cwd already lives under a work root (it's mounted already).
  # The docker sidecar still only sees ~/code, so testcontainers bind-mounting
  # this dir won't reach it — that's an intentional limit of the ad-hoc mount.
  if [ "$CAGE_MOUNT_CWD" = "1" ] && ! _cage_under_work_root "$PWD"; then
    _cage_bind rw "$PWD" "$PWD"
  fi

  # Scratch space the triage-issue skill clones repos into and writes reports to.
  _cage_bind rw "$HOME/triage-issues" "$CAGE_HOME/triage-issues"

  # Host-executed scripts within ~/.claude, overlaid read-only so an injected
  # prompt cannot plant code that later runs on the host as you (DESIGN §2/§7).
  _cage_bind ro "$HOME/.claude/hooks" "$CAGE_HOME/.claude/hooks"
  _cage_bind ro "$HOME/.claude/settings.json" "$CAGE_HOME/.claude/settings.json"
  _cage_bind ro "$HOME/.claude/settings.local.json" "$CAGE_HOME/.claude/settings.local.json"
  _cage_bind ro "$HOME/.claude/statusline-command.sh" "$CAGE_HOME/.claude/statusline-command.sh"

  # VCS identity (ro) so commits carry the right author; no SSH keys (DESIGN §7).
  # .gitconfig's `includeIf "gitdir:~/code/"` pulls in .gitconfig-code, which is the
  # active config for repos under ~/code (the cage's workspace); mount it too or the
  # include silently no-ops. Both point `core.excludesfile` at a global ignore file
  # (~/.gitignore, ~/.gitignore-code) via absolute paths that match the container
  # home, so mount those ro as well — otherwise git/jj in the cage see no excludes.
  _cage_bind ro "$HOME/.gitconfig" "$CAGE_HOME/.gitconfig"
  _cage_bind ro "$HOME/.gitconfig-code" "$CAGE_HOME/.gitconfig-code"
  _cage_bind ro "$HOME/.gitignore" "$CAGE_HOME/.gitignore"
  _cage_bind ro "$HOME/.gitignore-code" "$CAGE_HOME/.gitignore-code"
  # jj caches each repo's gitoxide trust level under ~/.config/jj/repos/<hash>. A
  # lone file-mount of config.toml lets podman create the parent ~/.config/jj owned
  # by root, so jj (uid 1000) can't write repos/ -> "Failed to determine the secure
  # config for a repo". Mount the host dir rw so it's user-owned (trust records also
  # persist + match the host, since ~/code lives at the same path); config.toml
  # stays ro, nested on top.
  _cage_bind rw "$HOME/.config/jj" "$CAGE_HOME/.config/jj"
  _cage_bind ro "$HOME/.config/jj/config.toml" "$CAGE_HOME/.config/jj/config.toml"

  # Skills' scripts (on PATH).
  _cage_bind ro "$HOME/scripts" "$CAGE_HOME/scripts"
  # puff symlink target (resolves ~/code symlinks). rw because repos symlink their
  # `my-prds` dir here, and those PRDs are written to from within the cage.
  _cage_bind rw "$HOME/.local/share/puff/projects" "$CAGE_HOME/.local/share/puff/projects"

  # nvim config + data (ro) for the formatting hook (DESIGN §9). State is a volume.
  _cage_bind ro "$HOME/.config/nvim" "$CAGE_HOME/.config/nvim"
  _cage_bind ro "$HOME/.local/share/nvim" "$CAGE_HOME/.local/share/nvim"

  # Credentials — mount config FILES (not dirs) for tools that also write caches,
  # so caches land in container-private paths and the tool still works (DESIGN §7).
  _cage_bind ro "$(_cage_docker_config)" "$CAGE_HOME/.docker/config.json"
  _cage_bind ro "$HOME/.npmrc" "$CAGE_HOME/.npmrc"
  _cage_bind ro "$HOME/.config/NuGet" "$CAGE_HOME/.config/NuGet"
  _cage_bind ro "$HOME/.config/acli" "$CAGE_HOME/.config/acli"
  _cage_bind ro "$HOME/.config/gh" "$CAGE_HOME/.config/gh"
  # Context7 CLI (ctx7) OAuth tokens. Just the credentials file (ro), so the dir
  # is the tool's own writable container path for anything else it caches.
  _cage_bind ro "$HOME/.context7/credentials.json" "$CAGE_HOME/.context7/credentials.json"

  # A real, writable XDG_RUNTIME_DIR. The cage has no logind to create /run/user/1000,
  # so without this fnm — and anything else that uses the runtime dir — fails (see
  # etc/cage-env.sh). podman can't make a tmpfs root user-owned, so it's root-owned
  # mode 1777 (sticky, like /tmp) rather than the usual 0700; fine for a single-user
  # cage. The bus socket below must live OUTSIDE this tmpfs: a tmpfs at /run/user/1000
  # is stacked on top of, and hides, any bind nested within it.
  RUN_ARGS+=(--tmpfs /run/user/1000:rw,nosuid,nodev)

  # Notifications via the host session bus (DESIGN §9). Bound to a sibling path (not
  # $XDG_RUNTIME_DIR/bus) so the runtime tmpfs above doesn't shadow it; the matching
  # DBUS_SESSION_BUS_ADDRESS points here.
  _cage_bind ro "/run/user/1000/bus" "/run/cage/bus"
}

_cage_add_envs() {
  RUN_ARGS+=(
    --env AGENT_CAGE=1                    # cage marker (DESIGN §11)
    --env "DOCKER_HOST=unix://$CAGE_SOCK" # -> the sidecar (DESIGN §8)
    --env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/cage/bus"
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

    # No SSH keys are mounted (DESIGN §7), so GitHub SSH remotes (git@github.com:…)
    # can't push from the cage. Transparently route github.com over https and
    # authenticate with the forwarded GH_TOKEN via gh's git-credential helper.
    # Injected as cage-only env (not the ro host .gitconfig) so the host keeps
    # using SSH; jj picks it up because git.subprocess=true shells out to git.
    # Two identical insteadOf keys = a git multivar, covering both ssh URL forms.
    RUN_ARGS+=(
      --env "GIT_CONFIG_COUNT=3"
      --env "GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf"
      --env "GIT_CONFIG_VALUE_0=git@github.com:"
      --env "GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf"
      --env "GIT_CONFIG_VALUE_1=ssh://git@github.com/"
      --env "GIT_CONFIG_KEY_2=credential.https://github.com.helper"
      --env "GIT_CONFIG_VALUE_2=!gh auth git-credential"
    )
  fi

  # Forward the host's terminal identity so colors match. Without these, podman
  # defaults TERM to "xterm" and leaves COLORTERM unset, so Claude can't detect
  # truecolor support and downsamples its theme to the 16-color ANSI palette —
  # which the terminal renders with its brighter "bold" variants (the washed-out,
  # "everything brighter" look). Passed by name (value via the wrapper's own env).
  [ -n "${TERM:-}" ] && RUN_ARGS+=(--env TERM)
  [ -n "${COLORTERM:-}" ] && RUN_ARGS+=(--env COLORTERM)

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
  # (uid 1000 + the unprivileged subuid block). It lifts the masked-path,
  # dropped-capability, seccomp and read-only-/sys restrictions so the *nested*
  # dockerd can mount fresh /proc and /sys for the containers it launches —
  # without it, container starts fail with `mounting "proc"/"sysfs" ... operation
  # not permitted` and detached/testcontainers never reach "running". The
  # à-la-carte equivalents (--cap-add=all + seccomp/apparmor=unconfined +
  # unmask=all, with or without a writable /sys bind) are NOT enough: the nested
  # sysfs mount still gets EPERM. This is the standard way docker:dind-rootless runs.
  #
  # mask=/dev/bus is the one deviation from stock --privileged. Privileged
  # bind-mounts the host's entire /dev into the sidecar, leaking host hardware —
  # notably hot-plugged /dev/bus/usb/* USB nodes. The nested rootless runc then
  # tries to recreate those group-owned nodes for the containers it launches and
  # fails — `error creating device nodes: mount src=/dev/bus/usb/...` / OCI
  # BadRequest (containers/podman#4900). Masking /dev/bus hides them after the
  # /dev bind (a plain --tmpfs is clobbered by privileged's recursive /dev
  # re-bind; an explicit mask survives), so /dev/bus/usb is empty and nested
  # containers start cleanly. The sidecar needs zero host USB devices.
  #
  # --userns=keep-id aligns the daemon's socket owner with the host uid so cage
  # sessions can use it; but it maps only the host's single 65536-id subuid block
  # into the container, so the image's stock rootless:100000:65536 map is out of
  # range and rootlesskit's newuidmap fails. We mount a fitted subid map instead.
  # A failure here is NON-fatal: the sidecar only powers docker-in-cage
  # (testcontainers etc.). If it won't start we warn and let the caller continue
  # without it, rather than blocking claude-cage from launching entirely.
  if ! podman run -d --name "$CAGE_SIDECAR_NAME" \
    --privileged \
    --security-opt label=disable \
    --security-opt mask=/dev/bus \
    --userns=keep-id \
    --network host \
    --stop-timeout 30 \
    -e "DOCKER_HOST=unix://$CAGE_SOCK" \
    -v "$CAGE_ETC/sidecar-subid:/etc/subuid:ro" \
    -v "$CAGE_ETC/sidecar-subid:/etc/subgid:ro" \
    -v "$CAGE_VOL_SOCK:/sock:U" \
    -v "$CAGE_VOL_DOCKER_DATA:/home/rootless/.local/share/docker" \
    -v "$HOME/code:$HOME/code:rw" \
    "$CAGE_SIDECAR_IMAGE" \
    --host="unix://$CAGE_SOCK" "${extra[@]}" \
    >/dev/null; then
    cage_err "failed to start docker sidecar"
    return 1
  fi

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
