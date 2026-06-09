# Tag matching the wrappers' default (bin/_cage-lib.sh) so a local build can be
# run via `CAGE_IMAGE=agent-cage:local cage` / `claude-cage`.
image := "agent-cage:local"

# List available recipes (default).
default:
    @just --list

# Build the cage image locally with podman (heavy: Fedora + .NET + node + the
# Playwright browsers — first build is a full cold build, no shared GHCR cache).
build:
    podman build -t {{image}} .
