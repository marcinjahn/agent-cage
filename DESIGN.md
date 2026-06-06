# agent-cage — Design

A sandbox for running **Claude Code with all permissions enabled**
(`--dangerously-skip-permissions`) without endangering the host. Claude may freely
destroy work inside `~/code`, but cannot reach or damage the host OS, dotfiles, SSH/GPG
keys, browser data, or any other home directory content.

This document is the implementation spec. Every decision below was made deliberately;
rationale is included so an implementer understands the _why_ before changing the _what_.

**Status: no open design questions.** Every design choice is decided and recorded below.
The implementer's job is to build, not to decide. Two categories remain, and neither is
an open _design_ question:

- **One config value to fill in:** the GHCR namespace `<YOUR-GH-USER>` (§5/§6).
- **Empirical validation, not decisions:** items in §13 say "verify"/"confirm" — they are
  things to test against the real host (e.g. the exact `formatters_by_ft` set, that
  rootless DinD starts, that `.nvmrc` switching works). The expected outcome is stated;
  only confirmation is pending.

---

## 1. Goal & non-goals

**Goal:** a `claude-cage` command that behaves like normal `claude` but runs inside an
isolated container, with full permissions, while transparently preserving the host
integration the user relies on (settings, sessions, hooks, toolchains, credentials,
notifications, port access, testcontainers).

**Non-goals:**

- Protecting `~/code` from Claude. It is the work area, is rw-mounted, and is assumed to
  be under version control / backed up (the user uses `jj`).
- A general multi-tenant security boundary. This is a single-user developer convenience
  with a _meaningful_ but not airtight isolation boundary (see threat model).

---

## 2. Threat model — what the cage does and does not protect

**Protected (cannot be touched by Claude in the cage):**

- Host OS: `/`, `/etc`, `/usr`, system packages.
- The entire home directory **except** the explicitly mounted paths — dotfiles, SSH/GPG
  keys, browser profiles, `~/.local` (except the one puff dir), etc.
- Root: the cage never runs as root. The outer container runs as uid 1000; the inner
  docker daemon is rootless. A breakout lands as the unprivileged user, never root.

**Deliberately reachable / destroyable (accepted):**

- `~/code` (rw) and agent state in `~/.claude` (rw, _except_ the host-executed scripts —
  see below). The work and the agent state.
- Host network services — `--network host` is used (see §10). The cage shares the host
  network namespace.
- Anything reachable through the **docker sidecar**, bounded to `~/code` only (see §8).

**Closed escape path — host-executed `~/.claude` scripts (read-only in cage):**
`~/.claude` is mounted rw so sessions/history work, BUT `~/.claude/hooks/`,
`settings.json`, `settings.local.json`, and `statusline-command.sh` are overlaid
**read-only**. These run **on the host** (when you use host Claude), so if the cage could
rewrite them, an injected prompt could plant code that later executes _outside_ the cage
as you. Read-only overlays close that door. (See §7.)

**Accepted risk — secret exfiltration (not mitigated for now):** the cage mounts
credentials (docker/npm/nuget/kube/acli/gh, and the Claude token in
`~/.claude/.credentials.json`) readable by a full-permissions agent, with **open network
egress** (§10). The cage prevents _destruction_ of host data but does **not** prevent an
injected prompt from _reading those secrets and sending them out_. Accepted deliberately
for now; revisit with an egress allowlist and/or a minimal credential set if it becomes a
concern. Mitigation hooks are noted in §10/§7 for when that day comes.

**Explicitly rejected** (do not implement): mounting the host's rootful
`/var/run/docker.sock`, or running the cage `--privileged`. Either reintroduces
root-on-host and defeats the cage.

---

## 3. Decisions summary

| Area                      | Decision                                                                              | Rationale                                                                                                                |
| ------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Outer runtime             | **Rootless Podman**                                                                   | Runs as uid 1000; breakout is unprivileged. `--dangerously-skip-permissions` refuses to run as root anyway.              |
| Session model             | **Ephemeral, parallel containers** (`podman run --rm`) from one image                 | User runs multiple cage sessions in parallel; no fragile long-lived container.                                           |
| Durable toolchain         | **Baked into a base image**, rebuilt **daily by GitHub Actions**                      | Reproducible; auto-tracks latest Claude + tools.                                                                         |
| Ad-hoc installs / caches  | **Shared named volumes**                                                              | Persist across sessions and image rebuilds.                                                                              |
| Host protection           | **Strict write-allowlist**                                                            | Only `~/code`, `~/.claude`, and cage volumes are writable.                                                               |
| Toolchains                | **Fresh install in image** (no host-binary reuse)                                     | User's host setup (brew/asdf) is irrelevant; only the tools matter.                                                      |
| Node versions             | **`fnm`** + per-project `.nvmrc`, versions in a shared volume                         | Multiple node versions, auto-selected.                                                                                   |
| nvim / formatting         | **Mount the user's real `~/.config/nvim` + `~/.local/share/nvim` read-only**          | Formatting hook must behave exactly as on host. Cannot be baked (host-specific, GitHub can't see it).                    |
| Networking                | **`--network host`** for all sessions                                                 | Bidirectional port-forwarding "just works".                                                                              |
| Docker for testcontainers | **Single rootless-docker sidecar**, wrapper-managed, bounded to `~/code`              | testcontainers needs real Docker; sidecar is reliable (vs. fragile nested DinD) and keeps the escape surface = `~/code`. |
| Resource limits           | **`podman run --memory=4g --cpus=2`** per session (default, overridable)              | Favors many parallel sessions; `limited` becomes a no-op in-cage via `AGENT_CAGE`.                                       |
| Claude version            | Image ships latest; host and cage share `~/.claude`                                   | Daily rebuild keeps them aligned.                                                                                        |
| Host-executed scripts     | **`~/.claude/hooks`, settings, statusline mounted read-only** (within rw `~/.claude`) | Prevents the cage from poisoning code that later runs on the host (see §2/§7).                                           |
| Secret exfiltration       | **Accepted for now** (open egress + creds mounted)                                    | Cage protects against destruction, not exfiltration; revisit later (§2/§10).                                             |
| Version control           | **Commit yes; push via `gh`/https only** (git/jj identity mounted ro, no SSH keys)    | Safe default: agent can't push to arbitrary ssh remotes; GitHub https push works via mounted `gh` auth (§7).             |
| Extra toolchains          | **dotnet + node only; Dockerfile structured for one-block extension**                 | User's primary stack; adding Rust/Python/Go later must be a single documented edit (§5).                                 |
| Timezone                  | **`TZ=Europe/Warsaw` (CET)** in image/env                                             | Timestamps and time-relative reasoning match the user's locale.                                                          |
| In-cage auto-update       | **Disabled** (`DISABLE_AUTOUPDATER=1`)                                                | Cage Claude version is owned by the image; prevents writes/drift mid-session.                                            |
| SELinux                   | **`--security-opt label=disable`** (no `:z`/`:Z` relabel)                             | `:Z` would relabel all ~75 GB of `~/code` and mutate host labels; disable labeling instead.                              |

---

## 4. Host facts (the target environment)

These are concrete facts about the host the cage must integrate with. Re-verify at
implementation time; do not hardcode beyond what's noted.

- OS: **Fedora Linux 43**. User `mnj`, **uid/gid 1000**, home `/home/mnj`.
- `docker` (29.x, rootful, socket `root:docker`) and `podman` (5.8) both installed.
  User is in the `docker` group. **Use Podman as the outer runtime.**
- `~/code` (~75 GB) — the work area.
- `~/.claude` + `~/.claude.json` — settings, hooks, sessions, history, credentials,
  MCP config.
- Hooks (in `~/.claude/settings.json`, paths `~/.claude/hooks/*`):
  - `PreToolUse/Bash` → `intercept-build.sh` (needs `jq`; references `rtk` which is
    **absent even on host** — that branch is dormant; and strips a `limited ` prefix).
  - `PostToolUse/Edit|Write` → `format.sh` (runs `nvim --headless … conform.format`,
    then `npx eslint --fix` for JS/TS; honors `CLAUDE_NO_FORMAT`).
  - `Notification` → `notify-send 'Claude Code needs attention'`.
  - `WorktreeCreate`/`WorktreeRemove` → scripts. `statusLine` → `statusline-command.sh`.
- Toolchains the cage must provide (host locations are irrelevant — reinstall fresh):
  dotnet, node (multiple, via `.nvmrc`), formatters **csharpier / prettier / stylua /
  eslint**, plus `jq git jj gh acli kubectl`. (`acli` and `gh` are system binaries on
  host — must be installed in the image.)
- `~/scripts` — used by skills; contains `limited` (a CPU/mem limiter wrapper).
- Symlinks under `~/code` all point into **`~/.local/share/puff/projects/`** (created by
  the user's `puff` tool). That single dir must be readable for symlinks to resolve.
- MCP: one global server `esky-mcp-proxy` of type **http** (remote URL + auth in
  `~/.claude.json`) + 2 project-level. HTTP MCP needs only network + the shared config —
  no local server binary.
- Credentials present: `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.config/NuGet`, `~/.nuget`,
  `~/.config/gh`, `~/.config/acli`.
- VCS identity: `~/.gitconfig` and jj config (`~/.config/jj/config.toml`) on host —
  needed in the cage (ro) so commits have correct author. **No SSH keys** are mounted
  (push is via `gh`/https only — see §7).
- Notifications: Wayland session, `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`,
  `XDG_RUNTIME_DIR=/run/user/1000`. `notify-send` talks to the host notification daemon
  over that session bus socket.

---

## 5. The base image

Built by **GitHub Actions, daily**, pushed to GHCR (e.g. `ghcr.io/<YOUR-GH-USER>/agent-cage`).
Host-agnostic — contains nothing host-specific (the host nvim config is mounted at
runtime, see §9).

**Base:** Fedora 43 (must match host so mounted, ABI-sensitive artifacts — the user's
mason-compiled nvim formatters — run correctly).

**Build steps (Dockerfile):**

1. Create user `mnj` with uid/gid **1000**, home `/home/mnj`, login shell `bash`.
2. System packages: `git jq gh kubectl libnotify` + nvim + build basics + fuse-overlayfs
   (for rootless docker) + `acli` (install per Atlassian's Linux instructions).
3. **dotnet SDK:** **.NET 10** only. Add more versions later via the extra-toolchains
   block (below) if needed.
4. **node via `fnm`:** install `fnm`; install the **latest LTS** node as the default.
   Per-project versions are installed on demand into a shared volume (§7). Set `FNM_DIR`
   to a volume-backed path.
5. **Formatters:** `csharpier` (`dotnet tool install -g`), `prettier`, `eslint`,
   `stylua`. Place them on PATH. (These must match what the host nvim `conform` config
   invokes; verify the conform config's formatter names at implementation time.)
6. **`jj`** (jujutsu) + `git` — install latest.
7. **`docker` CLI** (client only — the daemon is the sidecar, §8) so `docker …` and
   testcontainers' client work via `DOCKER_HOST`.
8. **Claude Code** — install latest (native installer or npm global). Pin/record the
   version in an image label for debuggability.
9. **Rootless docker engine** for the sidecar image (may be a _separate_ image — see §8).
10. Set `TZ=Europe/Warsaw` (CET) and `DISABLE_AUTOUPDATER=1` as image env.
11. Configure PATH and shell init (`/etc/profile.d` + `BASH_ENV`, see §6/§9) for: fnm,
    dotnet tools, the cage-owned global install prefix (volume), and `~/scripts`.
12. Default working assumptions: non-root, `WORKDIR /home/mnj`.

**Toolchain extensibility (explicit requirement):** the image ships **dotnet + node
only**, but adding a language later (Rust, Python, Go, …) must be a **single, clearly
labelled Dockerfile block** — e.g. a `# --- extra toolchains (add here) ---` section
with one self-contained `RUN` per language, so the user edits one place and the daily
rebuild picks it up. Do not scatter toolchain installs.

**GitHub workflow:** `.github/workflows/build.yml`

- `on: schedule: cron daily` + `workflow_dispatch` + `push` (on Dockerfile change).
- Build, tag `latest` + dated tag, push to GHCR.
- The wrapper pulls `latest` (with a periodic/lazy `podman pull`; don't pull on every
  invocation — gate it, e.g. once/day, to keep launches fast).
- **GHCR auth:** if the image repo is **private**, the host needs `podman login ghcr.io`
  (a PAT with `read:packages`) for the pull to succeed; the README must cover this. A
  public package needs no login. The image is large (dotnet + node + nvim + docker
  client) — daily pulls cost bandwidth; the lazy/gated pull keeps that bounded.

---

## 6. The wrappers (`bin/`)

### `claude-cage` — the primary command

Pseudocode:

```
1. Resolve CWD. Require it to be under /home/mnj/code (else: error or warn).
2. Ensure base image present (lazy pull of :latest, rate-limited).
3. Ensure docker sidecar is up (see §8) — start if missing/unhealthy, else reuse.
4. exec podman run --rm -it \
     --userns=keep-id \
     --network host \
     --security-opt label=disable \   # do NOT relabel ~/code (~75 GB); see §7
     --memory=4g --cpus=2 \            # default cap; see §3 / overridable
     -w "$PWD" \
     <all mounts from §7> \
     <all envs from §6 env list> \
     ghcr.io/<YOUR-GH-USER>/agent-cage:latest \
     claude --dangerously-skip-permissions "$@"
```

Key points:

- **`--userns=keep-id`** maps host uid 1000 ↔ container uid 1000 so files in `~/code`
  keep correct ownership and `$PWD` resolves identically inside.
- **`-w "$PWD"`** starts Claude in the same dir → satisfies "start from cwd" and makes the
  session project-encoding identical to host (→ shared sessions).
- **`--rm`** + parallel invocations = independent parallel sessions.
- Forward extra args (`"$@"`) to `claude`.

**Environment passed in (`--env`):**

- `AGENT_CAGE=1` — the cage marker (see §11).
- `DOCKER_HOST=unix:///sock/docker.sock` — points at the sidecar (see §8).
- `CLAUDE_NO_FORMAT`, `CLAUDE_BYPASS_BUILD_SUMMARY` and any other relevant `CLAUDE_*` —
  forwarded from the host environment so they keep working.
- `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`, `XDG_RUNTIME_DIR=/run/user/1000`
  — for `notify-send` (see §9).
- `TZ=Europe/Warsaw`, `DISABLE_AUTOUPDATER=1` — also set in the image; listed here so the
  wrapper can override if needed.
- PATH-affecting vars (`FNM_DIR`, dotnet tool path, cage global prefix) — preferably set
  in image profile rather than per-invocation.

### `cage` — utility command

- `cage` (no args) → drop into an interactive bash shell in a fresh cage container (same
  mounts/flags) for installing/inspecting tools.
- `cage docker {status|stop|reset}` → inspect/stop/recreate the sidecar (rarely needed;
  day-to-day the sidecar is invisible).

---

## 7. Mounts & volumes

### Bind mounts (host → container, identical paths)

| Host path                         | Container path      | Mode   | Purpose                                                 |
| --------------------------------- | ------------------- | ------ | ------------------------------------------------------- |
| `~/code`                          | `/home/mnj/code`    | **rw** | the work                                                |
| `~/.claude`                       | `/home/mnj/.claude` | **rw** | sessions, history, creds — but with ro overlays below   |
| `~/.claude/hooks`                 | same                | **ro** | host-executed; ro prevents host-escape poisoning (§2)   |
| `~/.claude/settings.json`         | same (file)         | **ro** | host-executed hook/statusline config; ro (§2)           |
| `~/.claude/settings.local.json`   | same (file)         | **ro** | as above                                                |
| `~/.claude/statusline-command.sh` | same (file)         | **ro** | host-executed; ro (§2)                                  |
| `~/.claude.json`                  | same                | **rw** | MCP + project config                                    |
| `~/.gitconfig`                    | same (file)         | ro     | commit author identity                                  |
| `~/.config/jj/config.toml`        | same (file)         | ro     | jj identity                                             |
| `~/scripts`                       | same                | ro     | skills' scripts; provides `limited` (put on PATH)       |
| `~/.config/nvim`                  | same                | ro     | formatting hook — exact nvim config (§9)                |
| `~/.local/share/nvim`             | same                | ro     | nvim plugins + mason-installed formatters (§9)          |
| `~/.local/share/puff/projects`    | same                | ro     | resolves all puff symlinks under `~/code`               |
| `~/.kube/config`                  | same (file)         | ro     | kubectl auth (caches go to container-private `~/.kube`) |
| `~/.docker/config.json`           | same (file)         | ro     | registry auth                                           |
| `~/.npmrc`                        | same (file)         | ro     | npm auth                                                |
| `~/.config/NuGet`                 | same                | ro     | nuget sources/auth                                      |
| `~/.config/acli`                  | same                | ro     | acli auth                                               |
| `~/.config/gh`                    | same                | ro     | gh auth (also enables GitHub https push — §7 VCS note)  |
| `/run/user/1000/bus`              | same (socket)       | ro     | notifications via dbus                                  |

**SELinux:** use `--security-opt label=disable` (§6) rather than `:z`/`:Z` mount flags —
`:Z` would relabel the entire ~75 GB `~/code` tree and mutate host labels. Do not relabel.

**Version control:** git/jj identity is mounted ro so commits have the right author. **No
SSH keys / ssh-agent** are forwarded, so ssh-remote pushes won't work — this is the
intended safe default. Pushing to **GitHub works over https** via the mounted `~/.config/gh`
auth. To push from the cage, use `gh`-backed https remotes; otherwise push from the host.

**Future exfil mitigation hook:** to later reduce the credential blast radius (§2), drop
the rarely-needed cred mounts (e.g. kube/acli) and/or pair with an egress allowlist (§10).

Notes:

- Mount **config files**, not whole dirs, for tools that also write caches (kube, npm),
  so the cache lands in a container-private/volume path and the tool still works.
- nvim writable state (`~/.local/state/nvim`: shada, swap, lazy-lock) must be redirected
  to a writable location (tmpfs or volume) since the config/data mounts are ro (§9).

### Named volumes (persist across sessions and image rebuilds)

| Volume             | Mounted at                 | Purpose                                         |
| ------------------ | -------------------------- | ----------------------------------------------- |
| fnm node versions  | `$FNM_DIR`                 | installed node versions, shared across sessions |
| nuget packages     | `~/.nuget/packages`        | restore cache                                   |
| npm cache          | `~/.npm`                   | npm cache                                       |
| cage global prefix | e.g. `/opt/cage` (on PATH) | ad-hoc `npm i -g` / `dotnet tool install -g`    |
| nvim state         | `~/.local/state/nvim`      | writable nvim runtime state                     |

---

## 8. Docker sidecar (testcontainers)

**Why:** testcontainers requires real Docker (its Podman support is unreliable). A
nested rootless docker-in-docker inside each session proved too fragile to recommend, so
a single shared **rootless-docker sidecar** is used instead. It is the more reliable
design and keeps the escape surface bounded.

**Container:** named `agent-cage-docker`, long-lived, started/managed entirely by the
wrapper. Image: **start with the official `docker:dind-rootless`** image — only build a
custom rootless-dockerd image if a concrete gap appears (document the reason if so). Runs
as uid 1000, **not** `--privileged` (use `--device /dev/fuse` + fuse-overlayfs storage,
falling back to the `vfs` driver only if fuse-overlayfs proves unavailable).

**Lifecycle (wrapper-owned — user never manages it):**

- `claude-cage` checks `podman container exists agent-cage-docker` and health; starts it
  with `podman run -d` if absent/unhealthy, reuses otherwise.
- It stays running and is shared by all parallel sessions (one warm daemon, one shared
  image cache — re-pulls avoided across sessions).

**Socket sharing:** the sidecar's `dockerd` listens on a unix socket placed in a shared
named volume mounted at `/sock` in both the sidecar and every cage session. Sessions get
`DOCKER_HOST=unix:///sock/docker.sock`.

**Safety (critical):** the sidecar mounts **only `~/code`** (rw, at the identical path) —
required so testcontainers volume-binds referencing paths under `~/code` resolve inside
the daemon's filesystem. Because that is the _only_ host path the daemon can see, a
docker bind-mount escape is confined to `~/code` — the same boundary as the rest of the
cage. Do **not** give the sidecar broader mounts.

**Networking:** sidecar on host network so testcontainers' random mapped ports are
reachable from the (also host-networked) cage sessions. Validate testcontainers + Ryuk
behavior; document any needed `TESTCONTAINERS_*` env defaults.

**Disk growth & cleanup:** the shared daemon accumulates pulled images, stopped test
containers, volumes, and networks over time (especially if Ryuk fails to reap). The
sidecar's docker data lives on a dedicated named volume. `cage docker reset` recreates the
sidecar (prunes everything); document running it periodically, and rely on Ryuk for
per-test cleanup.

---

## 9. Formatting hook & nvim

The shared hook `~/.claude/hooks/format.sh` runs
`nvim --headless <file> +"lua require('conform').format(...)" +wq` and then
`npx eslint --fix` for JS/TS. To make it behave **exactly** as on the host:

- Mount the user's real **`~/.config/nvim` (ro)** and **`~/.local/share/nvim` (ro)** (lazy
  plugins + mason-installed formatters). Fedora-43 base ⇒ mason's compiled binaries run.
- Redirect nvim's writable state to a volume/tmpfs (`~/.local/state/nvim`), since config
  - data are ro and nvim writes shada/lazy-lock at runtime.
- Formatter resolution order on PATH: **mounted mason (`~/.local/share/nvim/mason/bin`)
  is primary** so the cage uses the exact same formatter binaries/versions as the host;
  the image-installed formatters (§5) are the **fallback** (and serve non-nvim callers
  like `npx eslint`). Put mason bin **ahead of** the image formatters on PATH. (Confirm
  the conform config's `formatters_by_ft` set — known: csharpier, prettier, stylua.)
- `npx eslint` requires node — provided by fnm.

These mounts are deliberately **not** baked into the GitHub image: GitHub runners can't
see the user's nvim config, and a runtime mount stays current automatically when the user
edits their nvim setup.

---

## 10. Networking

`--network host` for every cage session and the sidecar. Consequences:

- Bidirectional port-forwarding is free: host apps reachable at `localhost:<port>` from
  the cage, and apps Claude runs in the cage are reachable from the host.
- **Caveat:** parallel sessions share the host's port space — two sessions binding the
  same fixed port collide (user manages this). testcontainers uses random host ports, so
  it's unaffected.
- **Rootless caveat:** rootless Podman cannot bind privileged ports (<1024) by default.
  If Claude needs to serve on 80/443, either use a high port or grant
  `net.ipv4.ip_unprivileged_port_start` on the host. Prefer high ports.
- **Egress is open** (accepted, §2). The future mitigation is an allowlist: adapt
  Anthropic's `init-firewall.sh` (nftables/iptables) to permit only anthropic, npm,
  nuget, github, and the `esky-mcp-proxy` host + registries. Not implemented now; noted so
  the hook exists when revisited.

---

## 11. `limited` handling

The container is already CPU/mem-capped via `podman run --memory/--cpus`, and the host
`limited` (systemd/cgroup-based) won't work inside the container anyway. Resolution:

- The wrapper sets `AGENT_CAGE=1` in every session.
- The user adds one guard line at the top of `~/scripts/limited` (host-side; the dir is
  mounted ro into the cage, so the edit propagates):
  ```bash
  # Inside agent-cage the container is already capped — run the command directly.
  [ -n "$AGENT_CAGE" ] && exec "$@"
  ```

`AGENT_CAGE` also serves as a general "am I in the cage?" marker for any other script,
hook, or shell-prompt customization.

---

## 12. Requirement → mechanism (traceability)

| Original requirement                             | Mechanism                                                             |
| ------------------------------------------------ | --------------------------------------------------------------------- |
| Host `~/.claude` settings apply                  | `~/.claude` rw bind mount                                             |
| Install tools in cage, persist                   | Baked image + shared volumes (fnm versions, global prefix, caches)    |
| Still use host claude normally                   | Separate `claude-cage` command; host untouched                        |
| Access all of `~/code`                           | `~/code` rw mount                                                     |
| Copy/paste host absolute paths (within `~/code`) | Identical `/home/mnj/code` path via `--userns=keep-id`                |
| Start from cwd                                   | `podman run -w "$PWD"`                                                |
| Works like normal, different command             | `claude-cage` wrapper                                                 |
| Symlinks outside `~/code`                        | `~/.local/share/puff/projects` ro mount (covers all puff links)       |
| Access `~/scripts`                               | ro mount, on PATH                                                     |
| Sessions shared both ways                        | Path identity + shared `~/.claude`                                    |
| Notification hook → host                         | dbus session-bus socket mount + `notify-send` in image                |
| Formatting hook (nvim)                           | Fedora base + ro mounts of nvim config/data + formatters on PATH      |
| `CLAUDE_NO_FORMAT` etc.                          | Wrapper forwards `--env`                                              |
| Bidirectional port-forward                       | `--network host`                                                      |
| Auth: docker/kubectl/npm/nuget/gh/acli/MCP       | ro config mounts + shared `~/.claude.json` (MCP) + sidecar for docker |

---

## 13. Known risks & validation checklist

Implement, then verify each of these empirically:

- [ ] **Rootless docker sidecar** starts reliably without `--privileged` (fuse-overlayfs
      or vfs storage). This is the highest-risk component.
- [ ] **testcontainers** end-to-end: spin a DB from a test under `~/code`, with
      `DOCKER_HOST` → sidecar socket; verify port reachability and Ryuk cleanup. Document
      any `TESTCONTAINERS_*` env needed.
- [ ] **Formatting hook** produces byte-identical output to the host for C#/TS/Lua files.
- [ ] **`.nvmrc` auto-selection** works in Claude's non-interactive Bash shells (wire
      `fnm env --use-on-cd` via `BASH_ENV`; verify `node -v` picks up `.nvmrc` after `cd`).
- [ ] **Notifications** from the cage appear on the host desktop.
- [ ] **Sessions** created in the cage are visible/resumable on the host and vice-versa.
- [ ] **Hook/settings ro overlay** holds: cage cannot write `~/.claude/hooks`,
      `settings.json`, `settings.local.json`, `statusline-command.sh` (verify writes fail).
- [ ] **VCS:** commits in the cage carry the correct author (git + jj); GitHub https push
      via `gh` works; ssh-remote push is unavailable (expected).
- [ ] **SELinux:** mounting `~/code` with `label=disable` does **not** relabel the tree or
      change host file labels.
- [ ] **TZ** inside the cage is CET; **`DISABLE_AUTOUPDATER`** prevents in-session updates.
- [ ] **Toolchain extension:** adding a language is a single Dockerfile block that
      survives the daily rebuild.
- [ ] **GHCR pull** works on the host (login if the package is private).
- [ ] **Concurrent writes**: running host-claude + multiple cage sessions simultaneously
      doesn't corrupt `~/.claude/history.jsonl` / sessions (mild risk; observe).
- [ ] **`--userns=keep-id`** yields correct file ownership in `~/code` (no root-owned
      files appearing on host).
- [ ] **`--dangerously-skip-permissions`** runs (must be non-root inside — it is) and
      note the residual circuit-breaker prompts for `.git`/`.claude` writes.
- [ ] **Claude version** in image vs host stays compatible across the daily rebuild.
- [ ] **Image pull rate-limiting** in the wrapper keeps launches fast.

---

## 14. Repo layout

```
agent-cage/
  DESIGN.md                  # this file
  Dockerfile                 # base image (§5)
  docker-sidecar/            # rootless-docker sidecar image (if custom; §8)
  .github/workflows/build.yml# daily build + push to GHCR (§5)
  bin/
    claude-cage              # primary wrapper (§6)
    cage                     # shell + `cage docker {status,stop,reset}` (§6)
  README.md                  # install: put bin/ on PATH; one-time host setup
```

**One-time host setup the README must cover:**

- Put `bin/` on PATH.
- Add the `AGENT_CAGE` guard to `~/scripts/limited` (§11).
- First run pulls the image and starts the sidecar automatically.

---

## 15. Suggested implementation order

1. Base `Dockerfile` + GitHub daily build → pull a working image.
2. `claude-cage` wrapper with mounts/env/flags (no sidecar yet) → confirm Claude runs,
   sessions/settings/notifications/formatting work.
3. `fnm` + `.nvmrc` wiring → confirm node version switching.
4. Rootless-docker sidecar + `DOCKER_HOST` + `cage docker` subcommand → confirm
   testcontainers.
5. Volumes for persistence; resource caps; image pull rate-limiting; `cage` shell.
6. Work through the §13 validation checklist.
