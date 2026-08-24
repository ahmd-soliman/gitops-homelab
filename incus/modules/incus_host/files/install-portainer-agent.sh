#!/usr/bin/env bash
# Install (or update) Portainer Agent. Detects image-tag drift and recreates
# the container; otherwise no-op. Reads PORTAINER_AGENT_VERSION from env
# (set by the caller via /etc/portainer-agent.env, mounted as a systemd
# EnvironmentFile from portainer-agent.service).
set -euo pipefail

: "${PORTAINER_AGENT_VERSION:?required}"

# Image pulls occasionally drop mid-stream ("connection reset by peer") and
# the bare `docker run` form would leave us with no container at all once the
# existing one is removed. Retry the pull with backoff before touching the
# running container.
pull_with_retry() {
    local image="$1"
    local attempts=5 delay=5
    for i in $(seq 1 "$attempts"); do
        if docker pull "$image"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            echo "[install-portainer-agent] pull failed (attempt $i/$attempts), retrying in ${delay}s" >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    echo "[install-portainer-agent] pull failed after $attempts attempts" >&2
    return 1
}

desired_image="portainer/agent:${PORTAINER_AGENT_VERSION}"
current_image=$(docker inspect portainer_agent --format '{{.Config.Image}}' 2>/dev/null || echo "")

if [ "${current_image}" = "${desired_image}" ]; then
    echo "[install-portainer-agent] already at ${desired_image} — no-op"
    exit 0
fi

echo "[install-portainer-agent] (re)installing ${desired_image}"
pull_with_retry "${desired_image}"
docker rm -f portainer_agent >/dev/null 2>&1 || true
docker run -d \
    --name portainer_agent \
    --restart=always \
    -p 9001:9001 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    "${desired_image}"
echo "[install-portainer-agent] done"
