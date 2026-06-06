# shellcheck shell=bash
# agent-cage shell environment (DESIGN §6/§9).
#
# Sourced two ways inside the cage:
#   - login/interactive shells, via the /etc/profile.d/cage.sh symlink;
#   - non-interactive bash (Claude's Bash tool, the format hook), via BASH_ENV.
#
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
