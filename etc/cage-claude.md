# Running inside agent-cage

You run in a rootless Podman container (the "cage"), not directly on the host.
Permission errors or missing paths outside the dirs below come from the cage, not
from Claude Code's sandbox; disabling the sandbox won't help.

- `docker` talks to a shared sidecar daemon that sees only `~/code`, `~/tmp` and
  `/tmp/claude-1000` (your scratchpad). Bind-mount sources (`docker run -v`,
  testcontainers binds) must be under one of those; any other path (`~/.nuget`,
  `/tmp/foo`, …) resolves to a missing or empty dir in the daemon, even though it exists
  for you. `docker build` contexts and `docker cp` work from anywhere.
- Most of the home directory is absent or read-only. Writable: `~/code`, `~/tmp`, `/tmp`
  and a few tool caches.
- No root: `sudo`/`dnf` won't work. `npm i -g` works and persists; for anything else
  that's missing, tell the user instead of working around it.
- Networking is the host's: ports you bind are host ports, shared with other sessions.
  Ports below 1024 can't be bound. Host and other sessions' processes are invisible, so
  if a port is busy, pick another one instead of looking for its owner.
