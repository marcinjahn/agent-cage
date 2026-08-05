# agent-cage

Run **Claude Code** or **Antigravity CLI (agy)** in a selectable permission mode without endangering
the host. The agent may freely change anything inside `~/code`, `~/.claude` and `~/.gemini`, but cannot
reach or damage the host OS, dotfiles, SSH/GPG keys, browser data, or anything else in your
home directory. For a fully unattended session, `--mode bypass` skips every permission
check (`--dangerously-skip-permissions`).

It runs Claude inside a rootless **Podman** container that transparently preserves your
host integration: settings, sessions, hooks, toolchains, credentials, notifications, port
access, and testcontainers. See [`DESIGN.md`](DESIGN.md) for the full spec, threat model,
and rationale.

> **Boundary, not airtight.** The cage protects against _destruction_ of host data. It
> does **not** currently prevent an injected prompt from _reading_ the mounted credentials
> and exfiltrating them over the open network (see `DESIGN.md` §2). It is a single-user
> developer convenience with a meaningful — but not airtight — isolation boundary.

## What you get

| Command                     | What it does                                                          |
| --------------------------- | --------------------------------------------------------------------- |
| `claude-cage [args…]`       | like `claude` but inside the cage; forwards args to `claude`          |
| `claude-cage --mode <mode>` | pick the permission mode for Claude (default `auto`; see `--help`)    |
| `claude-cage --mount-cwd`   | run from a dir outside the work roots; mounts the cwd into the cage   |
| `claude-cage --kube`        | mint + mount read-only kubectl access (see "Kubernetes access" below) |
| `claude-cage --help`        | list Claude-cage modes and usage                                      |
| `agy-cage [args…]`          | like `agy` but inside the cage; forwards args to `agy`                |
| `agy-cage --mode <mode>`    | pick the permission mode for agy (default `default`; see `--help`)    |
| `agy-cage --mount-cwd`      | run from a dir outside the work roots; mounts the cwd into the cage   |
| `agy-cage --kube`           | mint + mount read-only kubectl access (see "Kubernetes access" below) |
| `agy-cage --help`           | list agy-cage modes and usage                                         |
| `cage`                      | interactive shell in a fresh cage container (inspect/install)         |
| `cage --kube`               | same, for the interactive shell                                       |
| `cage docker status`        | inspect the shared rootless-docker sidecar (testcontainers)           |
| `cage docker stop`          | stop/remove the sidecar                                               |
| `cage docker reset`         | recreate the sidecar, pruning all its images/containers/data          |

## Requirements

- **Fedora 43** host, user `mnj`, uid/gid **1000** (the image is built to match — see
  `DESIGN.md` §4/§5).
- **Podman** (rootless). `docker` is not required on the host.
- The base image is pulled from `ghcr.io/marcinjahn/agent-cage:latest`, rebuilt daily by
  GitHub Actions.

## Install

1. **Put `bin/` on your PATH.** For fish:

   ```fish
   fish_add_path ~/code/private/agent-cage/bin
   ```

2. **GHCR login (only if the package is private).** The pull needs a token with
   `read:packages`:

   ```sh
   podman login ghcr.io
   ```

   A public package needs no login.

3. **Add the `AGENT_CAGE` guard to `~/scripts/limited`** so it is a no-op inside the cage
   (the container is already CPU/mem-capped — `DESIGN.md` §11). Add this near the top,
   after the shebang:

   ```bash
   # Inside agent-cage the container is already capped — run the command directly.
   [ -n "$AGENT_CAGE" ] && exec "$@"
   ```

   `~/scripts` is mounted read-only into the cage, so the edit propagates automatically.

4. **First run** pulls the image and starts the docker sidecar automatically:

   ```sh
   cd ~/code/<some-project>
   claude-cage
   ```

## Background image refresh (optional)

The wrappers already refresh `:latest` lazily on launch (rate-limited by
`CAGE_PULL_INTERVAL`). If you'd rather keep both images warm in the background even
between sessions, install the systemd `--user` timer:

```sh
just install-autopull        # or: bin/cage-autopull install
```

This pulls both the cage image (`ghcr.io/marcinjahn/agent-cage:latest`) and the dind
sidecar image (`docker.io/library/docker:dind-rootless`) on an `hourly` schedule. Manage
it with `bin/cage-autopull status` / `uninstall`; override the schedule or images via
`CAGE_PULL_SCHEDULE`, `CAGE_IMAGE`, and `CAGE_SIDECAR_IMAGE`.

User timers only run while you have an active session — to pull while logged out, enable
lingering: `sudo loginctl enable-linger $USER`.

## How it works (quick map)

- **Image** (`Dockerfile`): Fedora 43 + .NET 10 & 9, node via `fnm`, Python, Ruby, Rust (rustup),
  formatters (csharpier/prettier/stylua/eslint/rustfmt),
  `jj`/`git`/`gh`/`acli`/`just`/`jq`/`yq`/`difft`/`ctx7`/`pnpm`/`bun`/`terraform`/`tofu`/`ccusage`, docker CLI,
  `kubectl` (read-only access only — see below), the Playwright CLI (with Google Chrome), Claude Code,
  Antigravity CLI (agy), and the GitHub Copilot CLI. Built daily and pushed to GHCR.
- **Wrappers** (`bin/`): `claude-cage`, `agy-cage`, and `cage` share `_cage-lib.sh`, which assembles all
  podman mounts/env/flags, does the rate-limited image pull, and manages the sidecar.
- **Mounts** (`DESIGN.md` §7): `~/code`, `~/.claude`, and `~/.gemini` are read-write; the host-executed
  `~/.claude` and `~/.gemini/config` scripts/skills/settings are overlaid
  **read-only**; credentials, VCS identity, and the nvim config/data are read-only.
- **Sidecar** (`DESIGN.md` §8): one shared rootless-docker container
  (`docker:dind-rootless`), bounded to `~/code`, exposing a socket the cage reaches via
  `DOCKER_HOST`. Started/managed entirely by the wrappers.

## Kubernetes access (optional, read-only, opt-in)

`kubectl` is in the image, but the cage is never given your real (read-write) kubeconfig —
RBAC is enforced server-side, so mounting it read-only would only stop the _file_ from
being edited, not what `kubectl` could do against the API. Instead:

1. **One-time, cluster-side**, for each cluster you want reachable: create a dedicated
   ServiceAccount and bind it to the built-in read-only `view` ClusterRole, e.g.

   ```sh
   kubectl --context <ctx> create namespace agent-cage
   kubectl --context <ctx> create serviceaccount cage-viewer -n agent-cage
   kubectl --context <ctx> create clusterrolebinding cage-viewer-view \
     --clusterrole=view --serviceaccount=agent-cage:cage-viewer
   ```

2. **List the context** in `~/.config/agent-cage/kube-contexts` (outside this repo — host-
   specific, not checked in), one context name per line. See the comments in that file for
   the format (namespace/serviceaccount default to `agent-cage`/`cage-viewer`).

3. **Pass `--kube`** on any wrapper (`claude-cage --kube`, `agy-cage --kube`, `cage --kube`).
   Only then does the wrapper mint a short-lived (`CAGE_KUBE_TOKEN_TTL`, default `1h`) token
   per listed context and mount a generated, token-based kubeconfig into the cage. Without
   `--kube`, no token is minted and `kubectl` inside the cage has no config at all.

## Configuration (env vars)

| Var                    | Default                                | Purpose                                                                          |
| ---------------------- | -------------------------------------- | -------------------------------------------------------------------------------- |
| `CAGE_IMAGE`           | `ghcr.io/marcinjahn/agent-cage:latest` | base image reference                                                             |
| `CAGE_MEMORY`          | `4g`                                   | per-session memory cap                                                           |
| `CAGE_CPUS`            | `2`                                    | per-session CPU cap                                                              |
| `CAGE_PULL_INTERVAL`   | `86400`                                | min seconds between `:latest` checks (`0` = every launch; `--update` forces one) |
| `CAGE_NO_PULL`         | `0`                                    | `1` skips the registry check and runs the cached image as-is (`--no-update`)     |
| `CAGE_KUBE_TOKEN_TTL`  | `1h`                                   | validity of the minted read-only kubectl tokens (`--kube`)                       |
| `CAGE_SIDECAR_STORAGE` | _(unset)_                              | set to `vfs` if fuse-overlayfs is absent                                         |

## Notes & limitations

- **Pushing code:** commits get the right author (git + jj configs mounted ro). GitHub
  push works over **https** via the forwarded `gh` auth — **No SSH keys** are mounted, so
  the cage rewrites `git@github.com:` remotes to https transparently (cage-only; the host
  keeps using SSH). Non-GitHub ssh-remote pushes still won't work from the cage — push
  those from the host. (`DESIGN.md` §7)
- **Ports:** `--network host` makes host↔cage port-forwarding free, but parallel sessions
  share the host port space. Rootless Podman can't bind ports <1024 — use high ports.
- **Work roots:** `claude-cage` only launches from inside `~/code` or `~/triage-issues`
  (the rw-mounted roots), so the cwd resolves to real files in the cage. To work elsewhere,
  pass `--mount-cwd`, which bind-mounts the current dir into the cage **read-write** at the
  same path. If that dir is otherwise mounted read-only (e.g. `~/.config/nvim`), the
  read-write cwd mount takes precedence. The docker sidecar still only sees `~/code`, so
  testcontainers bind-mounting an ad-hoc cwd won't reach it. (`DESIGN.md` §6/§8)
- **Adding a language** (Rust/Python/Go/…): add one `RUN` block in the clearly-labelled
  `--- extra toolchains (add here) ---` section of the `Dockerfile`; the daily rebuild
  picks it up.
- **Sidecar disk growth:** run `cage docker reset` periodically to prune the shared
  daemon's accumulated images/volumes.

## Validation

After standing this up, work through the empirical checklist in `DESIGN.md` §13 (rootless
docker, testcontainers, formatting parity, `.nvmrc` switching, notifications, session
sharing, the read-only overlay, VCS, SELinux, TZ, etc.).
