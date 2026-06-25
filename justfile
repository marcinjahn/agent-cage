# Tag matching the wrappers' default (bin/_cage-lib.sh) so a local build can be
# run via `CAGE_IMAGE=agent-cage:local cage` / `claude-cage`.
image := "agent-cage:local"

# List available recipes (default).
default:
    @just --list

# Build the cage image locally with podman (heavy: Fedora + .NET + node +
# Google Chrome — first build is a full cold build, no shared GHCR cache).
build:
    # --format docker: the Dockerfile uses the SHELL instruction, which the
    # default OCI image format doesn't support (podman would warn and ignore it).
    podman build --format docker -t {{image}} .

# Install/enable the systemd --user timer that keeps the base image fresh.
install-autopull:
    bin/cage-autopull install
