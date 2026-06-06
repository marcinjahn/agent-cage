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
# it. Deduped per session via a marker dir in the container-private /tmp (fresh on
# every --rm launch), so a repeatedly-missing tool notifies once per session.
command_not_found_handle() {
  local cmd="$1"
  # Only bare tool names are image candidates — skip paths and local scripts.
  if [[ "$cmd" == [A-Za-z0-9_-]* && "$cmd" != *[!A-Za-z0-9_-]* ]]; then
    local seen="${TMPDIR:-/tmp}/.cage-missing-tools"
    mkdir -p "$seen" 2>/dev/null
    if [ ! -e "$seen/$cmd" ]; then
      : >"$seen/$cmd" 2>/dev/null || true
      notify-send -a agent-cage "agent-cage: missing tool '$cmd'" \
        "Claude tried to run '$cmd', which isn't in the cage image. Consider adding it to the Dockerfile." \
        >/dev/null 2>&1 || true
    fi
  fi
  printf '%s: command not found\n' "$cmd" >&2
  return 127
}

# The guard makes it idempotent so nested bash invocations don't re-run fnm or
# stack PATH entries.
[ -n "${__CAGE_ENV_DONE:-}" ] && return 0
export __CAGE_ENV_DONE=1

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
export PATH="/home/mnj/.local/share/nvim/mason/bin:/home/mnj/.local/bin:/opt/cage/bin:/opt/dotnet-tools:/opt/dotnet:/home/mnj/scripts:/usr/local/bin:$PATH"

# fnm with --use-on-cd so `.nvmrc` auto-selects node after `cd` (DESIGN §13).
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --shell bash 2>/dev/null)" || true
fi
