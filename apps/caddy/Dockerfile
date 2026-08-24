# Caddy with the Cloudflare DNS module baked in (needed for ACME DNS-01 on the
# wildcard/LAN hosts — the stock caddy image doesn't ship DNS providers).
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
# Bake the Caddyfile in rather than bind-mounting it. Komodo's periphery runs
# compose with repo paths under /etc/komodo/repos, but the host daemon resolves
# bind sources on the host fs (where the clone is /mnt/P2/.../komodo/repos), so a
# relative `./Caddyfile` mount mis-resolves -> Docker makes an empty dir ->
# "mount a directory onto a file". Baking sidesteps it (build context is streamed,
# not path-resolved). pull_policy:build rebuilds each deploy, so edits still apply.
COPY Caddyfile /etc/caddy/Caddyfile
