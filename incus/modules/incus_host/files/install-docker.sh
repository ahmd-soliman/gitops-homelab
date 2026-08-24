#!/usr/bin/env bash
# Idempotent docker-ce install. Re-running is a no-op once docker is present.
# Same logic as docker-stacks/provisioning/incus/bootstrap.sh, isolated so it
# can be reused by any host module caller.
set -euo pipefail

if command -v docker >/dev/null 2>&1; then
    echo "[install-docker] docker already present — skipping"
    exit 0
fi

echo "[install-docker] installing docker-ce"
apt-get update -y
apt-get install -y gnupg apt-transport-https ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
echo "[install-docker] done"
