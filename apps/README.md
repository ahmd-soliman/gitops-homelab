# Docker Stacks

This directory contains individual application configurations deployed as standard Docker Compose stacks. 

## GitOps Architecture

In this homelab setup, application deployments are managed via **Komodo** (as declared in the root [`komodo.toml`](../komodo.toml)):
1. A scheduled procedure in Komodo Core pulls updates from this Git repository.
2. Komodo diffs the local `docker-compose.yml` configs.
3. If a stack configuration has changed, Komodo triggers a deployment to the host defined for that stack (using the Komodo Periphery agent on the target machine).

## Stacks List

| Stack | Folder | Purpose | Routing Type |
|---|---|---|---|
| **Caddy** | [`caddy/`](caddy) | Edge reverse proxy & wildcard SSL terminator | Bridged host port (80/443) |
| **DDNS Updater** | [`ddns-updater/`](ddns-updater) | Auto-updates Cloudflare A/AAAA records on WAN IP change | None (Internal daemon) |
| **Grafana** | [`grafana/`](grafana) | System metrics visualization dashboard | Proxied via Caddy |
| **Prometheus** | [`prometheus/`](prometheus) | Metrics scraper & time-series database | Proxied via Caddy |
| **Uptime Kuma** | [`uptime-kuma/`](uptime-kuma) | Service uptime monitors & alert notifications | Proxied via Caddy |
| **GitLab Runner** | [`gitlab-runner/`](gitlab-runner) | Standalone on-prem CI/CD job runner | None (agent/outbound only) |

## Volume/Data Layout

To keep hosts clean and stateless:
* Configuration files are baked directly into Docker images where possible (e.g., the Caddyfile in Caddy).
* State and persistent data volumes are mapped to absolute host paths under `/mnt/data/app-config/<stack-name>/` (typically ZFS datasets provisioned via Terraform).

---

## 🛡️ Caddy Edge Proxy (`apps/caddy`)

Caddy is the entrypoint reverse proxy and TLS terminator for all routed services.

### Why one wildcard cert instead of per-host certs
Every single-label `*.homelab.example` host shares ONE certificate, issued once via Let's Encrypt **DNS-01 over Cloudflare**. That means:
* Adding a route is a matcher + `handle` block in the `Caddyfile` — no new certificate or DNS record is needed.
* No per-hostname leakage into public Certificate Transparency logs.

### TLS DNS-01 Setup
This works even for LAN-only hosts with no public `:80`/`:443` exposure. It needs a Cloudflare token scoped to `Zone:DNS:Edit` passed as `CF_TOKEN` via a local gitignored `.env` file. The stock `caddy` image doesn't ship with DNS provider plugins, so Caddy is compiled with `caddy-dns/cloudflare` via `xcaddy` inside the `Dockerfile`.

### The `caddyfile-rev` Hash Trick
Since the Caddyfile is baked into the Docker image, a Caddyfile-only edit doesn't change `docker-compose.yml`. Most GitOps agents (like Komodo) diff the compose file to decide whether to redeploy, meaning Caddyfile changes alone would not trigger a deploy.
* **The Fix:** The first line of `docker-compose.yml` is a comment with the first 12 hex characters of the Caddyfile's SHA-256 hash. Bump it whenever you edit the Caddyfile:
  ```bash
  shasum -a 256 apps/caddy/Caddyfile | cut -c1-12
  ```

### Transition & Cutover Plan
1. Set `CADDY_HTTP_PORT` and `CADDY_HTTPS_PORT` to unused transitional ports (e.g. `8090` and `9443`) in the stack's environment.
2. Validate a route without updating DNS:
   ```bash
   curl --resolve grafana.homelab.example:9443:<host-ip> https://grafana.homelab.example:9443 -I
   ```
3. Stop the old proxy, unset the transitional ports to default back to `80`/`443`, and redeploy.

---

## 🌐 DDNS Updater (`apps/ddns-updater`)

An IP monitoring daemon ([ddns-updater](https://github.com/qdm12/ddns-updater)) that keeps Cloudflare DNS A/AAAA records synchronized with your homelab's dynamic public IP address.

### Configuration
* **Service Port:** `30007` (Mapped to host for administrative UI access if needed).
* **Storage Location:** `/mnt/data/app-config/ddns-updater` (holds status/updater cache).
* **DNS Provider Details:** Loaded dynamically. The stack reads variables from a local, gitignored `.env` file in the directory. Example configuration schema inside the updater data directory:
   ```json
   {
     "settings": [
       {
         "provider": "cloudflare",
         "zone_identifier": "your-zone-id",
         "token": "your-cloudflare-dns-edit-token",
         "domain": "homelab.example",
         "host": "@"
       }
     ]
   }
   ```

---

## 📊 Grafana (`apps/grafana`)

Grafana visualization platform for metrics and monitoring. It queries Prometheus as its data source to display dashboard metrics for the homelab.

### Configuration
* **Service Port:** `30037` (Mapped to host port)
* **Access URL:** `https://grafana.homelab.example` (Terminated and reverse-proxied by Caddy)
* **Storage Location:** `/mnt/data/app-config/grafana/data` and `/mnt/data/app-config/grafana/plugins`
* **Non-Root Execution:** Hardened to run under non-root UID/GID `568:568` for container security.
* **Server Root URL:** `GF_SERVER_ROOT_URL` must be set to `https://grafana.homelab.example/` in the environment to ensure cookie security and proper redirection path resolution behind the Caddy proxy.

---

## 📈 Prometheus (`apps/prometheus`)

Prometheus monitoring server and time-series database. It is configured to scrape metrics from node exporters and container stats across the homelab infrastructure.

### Configuration
* **Service Port:** `30104` (Mapped to host port)
* **Storage Location:** `/mnt/data/app-config/prometheus/data`
* **Configuration Location:** `/mnt/data/app-config/prometheus/config`
* **Non-Root Execution:** Runs under UID/GID `568:568` to ensure least-privilege security.
* **Arguments:** Launched with `--config.file=/config/prometheus.yml`, `--storage.tsdb.path=/data`, `--storage.tsdb.retention.time=365d` (1 year history), and `--storage.tsdb.wal-compression` (compresses the write-ahead log).

---

## ⏱️ Uptime Kuma (`apps/uptime-kuma`)

A self-hosted monitoring tool to track service status, ping latency, and DNS resolution, with automated notification integrations (Discord, Telegram, Gotify, etc.).

### Configuration
* **Service Port:** `30120` (Mapped to host port)
* **Access URL:** `https://uptime.homelab.example` (Terminated and reverse-proxied by Caddy)
* **Storage Location:** `/mnt/data/app-config/uptime-kuma/data`
* **Non-Root Execution:** Runs under UID/GID `568:568`.
* **IPv6 Network Workaround:** To prevent deployment agents from failing with `ParseAddr` errors due to malformed gateway suffixes, IPv6 is explicitly disabled on the compose network:
  ```yaml
  networks:
    default:
      enable_ipv6: false
  ```

---

## 🦊 GitLab Runner (`apps/gitlab-runner`)

An on-premises GitLab Runner agent that connects to a GitLab instance (either GitLab.com or a self-hosted server) to execute CI/CD pipeline jobs.

### Why on-premises runners make sense
Many developers do not realize how easy it is to register self-hosted runners to execute workloads locally. Running your own runners provides several advantages:
* **Cost & Resources:** Unlimited free CI/CD build minutes on your own hardware.
* **Speed:** Access to local build caches and storage speeds.
* **Secure LAN Access:** Allows CI/CD jobs to deploy directly to local Kubernetes clusters, Incus hosts, or Docker daemons without exposing those control plane ports to the public internet.

### Configuration
* **Registration Directory:** `/mnt/data/app-config/gitlab-runner/config` (holds the generated runner registration tokens and `config.toml`).
* **Docker Socket Mount:** Mounts the host's `/var/run/docker.sock` so that the runner can execute jobs inside clean, isolated throwaway Docker containers using the `docker` executor.

### Registration Guide
Deploy this stack via Komodo, then run the registration wizard inside the container to connect it to your GitLab repository or organization:

```bash
# Enter the container and trigger the register utility
docker exec -it gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.com/" \
  --registration-token "GLRT-YOUR_REGISTRATION_TOKEN" \
  --executor "docker" \
  --docker-image "alpine:latest" \
  --description "Homelab On-Prem Runner" \
  --tag-list "homelab,docker" \
  --run-untagged="true" \
  --locked="false" \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock"
```
Once registered, the configuration will persist in `/mnt/data/app-config/gitlab-runner/config/config.toml` on the host.
