#!/usr/bin/env bash
# Idempotently ensure each docker network in DOCKER_NETWORKS exists. Reads
# DOCKER_NETWORKS as a space-separated list from /etc/docker-networks.env
# (set as a systemd EnvironmentFile by docker-networks.service). No-op if a
# network already exists; never modifies driver/IPAM/options on an existing
# network — first creator wins.
set -euo pipefail

: "${DOCKER_NETWORKS:=}"

for net in $DOCKER_NETWORKS; do
    if docker network inspect "$net" >/dev/null 2>&1; then
        echo "[ensure-docker-networks] $net exists"
    else
        echo "[ensure-docker-networks] creating $net"
        docker network create "$net"
    fi
done
