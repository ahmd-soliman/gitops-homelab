# homelab.example DNS records — a representative sample. Real setup manages
# ~20 of these (one per routed host in apps/caddy/Caddyfile); trimmed here to
# the pattern, not the full list.
#
# Apex A/AAAA (if you run a dynamic-DNS updater) and any _acme-challenge TXT
# (Caddy's DNS-01 issuance) are intentionally NOT managed here — see
# README.md "Two records Terraform must never manage".

data "cloudflare_zone" "this" {
  name = var.zone_name
}

resource "cloudflare_record" "grafana" {
  zone_id = data.cloudflare_zone.this.id
  name    = "grafana"
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1
}

resource "cloudflare_record" "uptime" {
  zone_id = data.cloudflare_zone.this.id
  name    = "uptime"
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1
}

resource "cloudflare_record" "argocd" {
  zone_id = data.cloudflare_zone.this.id
  name    = "argocd"
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1
}

resource "cloudflare_record" "whoami" {
  zone_id = data.cloudflare_zone.this.id
  name    = "whoami"
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1
}

# Add one cloudflare_record block per single-label host you route in the
# Caddyfile. All CNAME -> apex, proxied through Cloudflare, ttl=1 (means
# "automatic" when proxied).
