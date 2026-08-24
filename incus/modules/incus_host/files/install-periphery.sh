#!/usr/bin/env bash
# Install (or update) Komodo Periphery. Detects image-tag, passkey, or
# core-public-key drift and recreates the container; otherwise no-op. Reads
# PERIPHERY_VERSION, PERIPHERY_PASSKEY, PERIPHERY_CORE_PUBLIC_KEYS from env
# (set by the caller in cloud-init runcmd).
set -euo pipefail

: "${PERIPHERY_VERSION:?required}"
: "${PERIPHERY_PASSKEY:?required}"
: "${PERIPHERY_CORE_PUBLIC_KEYS:?required}"

# Pulls from ghcr.io occasionally drop mid-stream ("connection reset by peer")
# and the bare `docker run` form would leave us with no container at all once
# the existing one is removed. Retry the pull with backoff before touching the
# running container.
pull_with_retry() {
    local image="$1"
    local attempts=5 delay=5
    for i in $(seq 1 "$attempts"); do
        if docker pull "$image"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            echo "[install-periphery] pull failed (attempt $i/$attempts), retrying in ${delay}s" >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    echo "[install-periphery] pull failed after $attempts attempts" >&2
    return 1
}

desired_image="ghcr.io/moghtech/komodo-periphery:${PERIPHERY_VERSION}"
current_image=$(docker inspect komodo-periphery --format '{{.Config.Image}}' 2>/dev/null || echo "")
current_passkey=$(docker inspect komodo-periphery \
    --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "PERIPHERY_SECRET"}}{{index (split . "=") 1}}{{end}}{{end}}' \
    2>/dev/null || echo "")
current_core_keys=$(docker inspect komodo-periphery \
    --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "PERIPHERY_CORE_PUBLIC_KEYS"}}{{index (split . "=") 1}}{{end}}{{end}}' \
    2>/dev/null || echo "")

if [ "${current_image}" = "${desired_image}" ] && [ "${current_passkey}" = "${PERIPHERY_PASSKEY}" ] \
    && [ "${current_core_keys}" = "${PERIPHERY_CORE_PUBLIC_KEYS}" ]; then
    echo "[install-periphery] already at ${desired_image} with matching passkey/core keys — no-op"
    exit 0
fi

echo "[install-periphery] (re)installing ${desired_image}"
pull_with_retry "${desired_image}"
docker rm -f komodo-periphery >/dev/null 2>&1 || true
# /config/keys persists Periphery's PKI keypair across recreations (version
# bumps, drift-repairs below). Without this, every recreation generates a
# fresh keypair, invalidating whatever public key Core has on file for this
# Server and knocking it offline until manually re-onboarded.
mkdir -p /var/lib/komodo-periphery/keys
docker run -d \
    --name komodo-periphery \
    --restart=always \
    -p 8120:8120 \
    -e PERIPHERY_SECRET="${PERIPHERY_PASSKEY}" \
    -e PERIPHERY_CORE_PUBLIC_KEYS="${PERIPHERY_CORE_PUBLIC_KEYS}" \
    -e PERIPHERY_SSL_ENABLED=false \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /proc:/proc:ro \
    -v /var/lib/komodo-periphery/keys:/config/keys \
    "${desired_image}"
echo "[install-periphery] done"
