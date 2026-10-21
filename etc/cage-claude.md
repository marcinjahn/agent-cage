# Running inside agent-cage

You run in a rootless Podman container (the "cage"), not directly on the host.
Permission errors or missing paths outside the dirs below come from the cage, not
from Claude Code's sandbox; disabling the sandbox won't help.

- `docker` talks to a shared sidecar daemon that sees only `~/code` and `~/tmp`
  (which holds your scratchpad, `~/tmp/claude-1000`). Bind-mount sources (`docker run -v`,
  testcontainers binds) must be under one of those; any other path (`~/.nuget`,
  `/tmp/foo`, …) resolves to a missing or empty dir in the daemon, even though it exists
  for you. `docker build` contexts and `docker cp` work from anywhere.
- Most of the home directory is absent or read-only. Writable: `~/code`, `~/tmp`, `/tmp`
  and a few tool caches. `/tmp` is private to this session and gone when it
  ends; `~/tmp` is shared with the host.
- No root: `sudo`/`dnf` won't work. `npm i -g` works and persists; for anything else
  that's missing, tell the user instead of working around it.
- Networking is the host's: ports you bind are host ports, shared with other sessions.
  Ports below 1024 can't be bound. Host and other sessions' processes are invisible, so
  if a port is busy, pick another one instead of looking for its owner.

## Headed browser (e.g. an SSO sign-in the user completes)

Browsers run headless by default. When the user has to see or use the browser (sign in,
solve a captcha), open it in a nested display window on their desktop:

1. `cage-display start` (if it says there's no display broker, tell the user what it
   printed and stop).
2. `XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=/run/cage/display/wayland-0 playwright-cli open --headed --browser chrome <url>`
   (`--browser firefox` works the same way). Chrome needs both variables; without
   `XDG_SESSION_TYPE=wayland` it tries X11 and fails with "Missing X server or $DISPLAY".
   Set them only on this command, never globally: they change how Claude Code and other
   tools behave.
3. Ask the user to sign in in the window, wait for them to say they're done, then continue
   with the usual `playwright-cli` commands.
4. When finished: `playwright-cli close`, then `cage-display stop`.

Don't use `--persistent` or `--profile` for these sessions: the default throwaway profile
keeps the user's login cookies from outliving the session. The window has no clipboard
link to the desktop, so the user types credentials directly into it.
