# Homelab app-config ZFS datasets, declared instead of clicked into
# existence. Uniform lz4 + atime=off. A brand-new dataset needs its parent
# present first (create_ancestors = false), so add parents before children.

locals {
  datasets = [
    "tank/app-config/caddy",
    "tank/app-config/caddy/config",
    "tank/app-config/caddy/data",
    "tank/app-config/grafana",
    "tank/app-config/grafana/data",
    "tank/app-config/grafana/plugins",
    "tank/app-config/prometheus",
    "tank/app-config/prometheus/config",
    "tank/app-config/prometheus/data",
  ]
}

resource "truenas_pool_dataset" "ds" {
  for_each = toset(local.datasets)

  name             = each.value
  type             = "FILESYSTEM"
  compression      = "LZ4"
  atime            = "OFF"
  comments         = "managed by terraform"
  share_type       = "APPS"
  create_ancestors = false

  lifecycle {
    # share_type is create-only + unreadable on import → would force replace.
    ignore_changes = [share_type]
  }
}

# A dataset whose PARENT is also newly-created in the same apply needs an
# explicit depends_on: for_each instances have no ordering between them, so
# a brand-new parent+child pair can race (the child's create call reaching
# the API before the parent's finishes → "Parent dataset does not exist").
# Once both exist, this can fold back into local.datasets/ds like any other
# already-adopted entry — it's only required for a genuinely-new pair.
resource "truenas_pool_dataset" "uptime_kuma" {
  name             = "tank/app-config/uptime-kuma"
  type             = "FILESYSTEM"
  compression      = "LZ4"
  atime            = "OFF"
  comments         = "managed by terraform"
  share_type       = "APPS"
  create_ancestors = false

  lifecycle {
    ignore_changes = [share_type]
  }
}

resource "truenas_pool_dataset" "uptime_kuma_data" {
  name             = "tank/app-config/uptime-kuma/data"
  type             = "FILESYSTEM"
  compression      = "LZ4"
  atime            = "OFF"
  comments         = "managed by terraform"
  share_type       = "APPS"
  create_ancestors = false
  depends_on       = [truenas_pool_dataset.uptime_kuma]

  lifecycle {
    ignore_changes = [share_type]
  }
}
