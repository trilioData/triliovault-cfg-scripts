#!/usr/bin/env bash
# setup_build_machine.sh — Prepare an Ubuntu machine for building TrilioVault
#                          Sunbeam Docker images and Juju charms.
#
# Idempotent: safe to re-run; already-installed tools are skipped.
# Supported OS: Ubuntu 22.04 LTS (Jammy) or 24.04 LTS (Noble).
# Canonical sunbeam-charms CI targets Ubuntu 24.04; both versions work.
#
# What this installs:
#   - Docker CE            (for building OCI images with devops-build-publish.sh)
#   - charmcraft (snap)    (for packing Juju charms with build_publish.sh)
#   - git, curl, python3   (dependencies)
#
# After running this script:
#   1. Log out and back in (or run `newgrp docker`) so docker group takes effect
#   2. Log in to Docker Hub: docker login
#   3. Log in to Charmhub:   charmcraft login --export creds.txt
#      (copy creds.txt from a machine with a browser, then:
#       export CHARMCRAFT_AUTH=$(cat creds.txt))
#
# Usage:
#   bash sunbeam-canonical/build/setup_build_machine.sh
#
# Run from any directory; script resolves its own location.

set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
skip() { echo "[$(date '+%H:%M:%S')] SKIP: $*"; }

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------
log "Installing base packages ..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    python3 \
    python3-pip \
    snapd \
    lsb-release

# ---------------------------------------------------------------------------
# Docker CE
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null; then
    skip "Docker already installed ($(docker --version))"
else
    log "Installing Docker CE ..."
    # Add Docker's official GPG key and APT repo
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    DISTRO=$(lsb_release -cs)
    ARCH=$(dpkg --print-architecture)
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${DISTRO} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    log "Docker CE installed: $(docker --version)"
fi

# Add current user to docker group (idempotent)
if id -nG "$USER" | grep -qw docker; then
    skip "User $USER already in docker group"
else
    log "Adding $USER to docker group ..."
    sudo usermod -aG docker "$USER"
    log "NOTE: log out and back in (or run 'newgrp docker') for group to take effect"
fi

# ---------------------------------------------------------------------------
# charmcraft (snap)
# ---------------------------------------------------------------------------
if snap list charmcraft &>/dev/null 2>&1; then
    CURRENT=$(snap list charmcraft | awk 'NR==2{print $2}')
    skip "charmcraft already installed (version $CURRENT)"
else
    log "Installing charmcraft snap ..."
    sudo snap install charmcraft --classic --channel latest/stable
    log "charmcraft installed: $(charmcraft --version)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "Build machine setup complete."
echo ""
echo "  Docker:     $(docker --version 2>/dev/null || echo 'installed — re-login for docker group')"
echo "  charmcraft: $(charmcraft --version 2>/dev/null)"
echo ""
echo "Next steps:"
echo "  1. Re-login or run 'newgrp docker' for docker group to take effect"
echo "  2. docker login"
echo "  3. charmcraft login   (or set CHARMCRAFT_AUTH env var if using exported creds)"
echo ""
echo "Then build:"
echo "  # Docker images:"
echo "  cd sunbeam-canonical/docker"
echo "  bash devops-build-publish.sh --tag 6.2.1-2024.1 --containers all --mode build-and-publish"
echo ""
echo "  # Juju charms:"
echo "  bash sunbeam-canonical/build/build_publish.sh --charms all --mode build-and-publish --channel 2024.1/stable"
