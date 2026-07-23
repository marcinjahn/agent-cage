# shellcheck shell=bash
# agent-cage shell environment (DESIGN §6/§9).
#
# Sourced two ways inside the cage:
#   - login/interactive shells, via the /etc/profile.d/cage.sh symlink;
#   - non-interactive bash (Claude's Bash tool, the format hook), via BASH_ENV.
#
# Missing-tool notifier (DESIGN §9): when Claude tries to run a command the image
# doesn't provide, pop a host desktop notification so the image can be updated to
# include it. Bash calls command_not_found_handle only on an actual exec attempt
# (not on `command -v`/`type` probes), so this fires on real use, not checks. It
# returns 127 to preserve normal "command not found" semantics. Defined BEFORE the
# idempotency guard below so it's present even in nested shells that short-circuit
# it. Deduped per session via a marker dir in the container-private
# /run/user/1000 tmpfs (fresh on every --rm launch), so a repeatedly-missing tool
# notifies once per session. NOT /tmp: that's bind-mounted from the host (shared
# across sessions) so a marker there would only ever notify once, ever.
command_not_found_handle() {
  local cmd="$1"
  # Only bare tool names are image candidates — skip paths and local scripts.
  if [[ "$cmd" == [A-Za-z0-9_-]* && "$cmd" != *[!A-Za-z0-9_-]* ]]; then
    local seen="${XDG_RUNTIME_DIR:-/tmp}/.cage-missing-tools"
    mkdir -p "$seen" 2>/dev/null
    if [ ! -e "$seen/$cmd" ]; then
      : >"$seen/$cmd" 2>/dev/null || true
      notify-send -a agent-cage "agent-cage: missing tool '$cmd'" \
        "The agent tried to run '$cmd', which isn't in the cage image. Consider adding it to the Dockerfile." \
        >/dev/null 2>&1 || true
    fi
  fi
  printf '%s: command not found\n' "$cmd" >&2
  return 127
}

# Idempotency without breaking sandboxed subshells. Key the skip on THIS shell's
# PATH (the mason bin dir below is prepended unconditionally, so it's a reliable
# sentinel), not on an exported flag. An exported "done" flag was wrong: Claude
# Code's Bash tool sources this file in a parent, exports the flag, then runs the
# command in a child whose PATH has been reset to the image's base ENV PATH. That
# child re-sourced this file, saw the inherited flag, and returned before re-adding
# node -> "node: command not found". Keying on PATH content means a shell with a
# reset PATH rebuilds it, while a nested shell that already inherited the enriched
# PATH still skips (no re-stacking, no redundant `fnm env`).
case ":${PATH}:" in
*":/home/mnj/.local/share/nvim/mason/bin:"*) return 0 ;;
esac

export DOTNET_ROOT=/opt/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export FNM_DIR=/opt/fnm
export NPM_CONFIG_PREFIX=/opt/cage
export TZ=Europe/Warsaw
export DISABLE_AUTOUPDATER=1

# Mason bin first so the cage uses the host's exact formatter binaries/versions;
# baked formatters (/opt/dotnet-tools, /usr/local/bin) are the fallback. Then
# Claude (~/.local/bin), the cage global prefix, dotnet, and the user's scripts.
export PATH="/home/mnj/.local/share/nvim/mason/bin:/home/mnj/.local/bin:/home/mnj/.cargo/bin:/opt/cage/bin:/opt/dotnet-tools:/opt/dotnet:/home/mnj/scripts:/usr/local/bin:$PATH"

# fnm: put node on PATH, then make `.nvmrc`/`.node-version` select the node version
# (DESIGN §13). --use-on-cd only fires on a `cd`, so a shell that *starts* inside the
# project — Claude's non-interactive Bash tool and the initial login shell — would
# otherwise keep the default LTS. We therefore apply the project's version file
# explicitly below (and on `cd`), installing it on demand: per-project versions are
# not baked, they land in the FNM_DIR volume on first use (DESIGN §5 step 4).
#
# fnm keeps a per-shell "multishell" symlink under $XDG_RUNTIME_DIR; the launcher
# provides a writable /run/user/1000 tmpfs for it (bin/_cage-lib.sh), since the cage has
# no logind to create one. Without that dir `fnm env` fails ("Can't create the symlink
# for multishells") and node silently falls back to Fedora's system node.
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --shell bash 2>/dev/null)" || true

  __cage_fnm_use() {
    if [ -f .nvmrc ] || [ -f .node-version ]; then
      # --install-if-missing so an unbaked version (e.g. 24.x) is fetched on demand;
      # output is dropped so it never pollutes Claude's Bash-tool command output.
      fnm use --install-if-missing --silent-if-unchanged >/dev/null 2>&1 || true
    fi
  }
  # Re-select on directory change (interactive shells), and once now for the
  # directory this shell was launched in.
  cd() {
    builtin cd "$@" || return
    __cage_fnm_use
  }
  __cage_fnm_use
fi
