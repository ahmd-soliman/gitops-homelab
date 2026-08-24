terraform {
  required_providers {
    incus = {
      source = "lxc/incus"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

# Cloud-init user-data is built here (not in a .tftpl file) because we want
# templatefile() to merge an arbitrary list of write_files / runcmd entries
# from the caller. Doing the merge in HCL keeps the template flat and avoids
# the "for loop inside a yaml template" footgun.
locals {
  # VMs only: a deterministic locally-administered MAC (02 prefix = locally
  # administered + unicast), derived from var.name so it's stable across
  # applies without needing the random provider or a read-after-create step.
  #
  # Why this exists: containers get their NIC renamed to "eth0" by Incus
  # inside the container namespace, so cloud-init's network-config matching
  # on "eth0" just works. VMs don't get that treatment — the guest kernel
  # names the virtio-net device via normal predictable naming (e.g.
  # "enp5s0"), which never matches netplan's hardcoded "eth0" key, so the
  # interface silently gets no config at all. Pinning + matching by MAC
  # sidesteps guest-side naming entirely.
  vm_nic_mac = "02:00:${substr(md5(var.name), 0, 2)}:${substr(md5(var.name), 2, 2)}:${substr(md5(var.name), 4, 2)}:${substr(md5(var.name), 6, 2)}"

  # Always-on packages installed via cloud-init at first boot AND re-applied
  # on every `terraform apply` via null_resource.apply_packages below — so
  # adding a new entry to this list propagates to existing hosts on the next
  # apply, not just to fresh ones. apt-get install -y is idempotent, so
  # already-present packages are no-ops; missing ones get installed.
  #
  # Removal posture: removing a package from this list does NOT uninstall it
  # from existing hosts (mirrors the docker_networks / periphery /
  # portainer-agent pattern below, which also doesn't tear down on removal —
  # safer than surprising the operator with disappearing software).
  #
  # avahi-daemon: announces this host as <name>.local via mDNS on the LAN.
  base_packages = ["openssh-server", "curl", "ca-certificates", "gnupg", "apt-transport-https", "avahi-daemon"]

  # Docker install — opt-in. Most callers want it; setting var.install_docker
  # to false skips both the install and the docker_networks block below.
  docker_writes = var.install_docker ? [{
    path        = "/usr/local/sbin/install-docker.sh"
    permissions = "0755"
    encoding    = "b64"
    content     = filebase64("${path.module}/files/install-docker.sh")
  }] : []

  docker_runs = var.install_docker ? ["/usr/local/sbin/install-docker.sh"] : []

  # Docker networks. Same self-heal pattern as periphery: a oneshot systemd
  # unit runs ensure-docker-networks.sh on every boot. The script is
  # idempotent (no-op if the network exists), so a /var/lib/docker wipe or a
  # manual `docker network rm` is recovered automatically on next boot —
  # without TF or cloud-init re-running. The list of networks lives in
  # /etc/docker-networks.env as a systemd EnvironmentFile so the unit picks
  # up changes without recompiling.
  docker_networks_writes = (var.install_docker && length(var.docker_networks) > 0) ? [
    {
      path        = "/usr/local/sbin/ensure-docker-networks.sh"
      permissions = "0755"
      encoding    = "b64"
      content     = filebase64("${path.module}/files/ensure-docker-networks.sh")
    },
    {
      path        = "/etc/systemd/system/docker-networks.service"
      permissions = "0644"
      encoding    = "b64"
      content     = filebase64("${path.module}/files/docker-networks.service")
    },
    {
      path        = "/etc/docker-networks.env"
      permissions = "0644"
      encoding    = "plain"
      content     = "DOCKER_NETWORKS=\"${join(" ", var.docker_networks)}\"\n"
    },
  ] : []

  docker_networks_runs = (var.install_docker && length(var.docker_networks) > 0) ? [
    "systemctl daemon-reload",
    "systemctl enable --now docker-networks.service",
  ] : []

  # Komodo Periphery — opt-in. The passkey is sensitive; passed in cleartext to
  # cloud-init (which lands at /var/lib/cloud/instance/user-data.txt on the
  # guest, mode 0600). Acceptable for a LAN-only host; rotate via terraform
  # apply if it leaks.
  #
  # The install runs from a oneshot systemd unit (not directly from runcmd) so
  # that any future boot — including after a /var/lib/docker wipe, manual
  # `docker rm`, or image purge — re-runs the idempotent install script and
  # restores the container without needing a `terraform apply`. Cloud-init's
  # role here is just to plant the script + unit + env file and enable the
  # unit; the actual install happens when systemd reaches multi-user.target.
  periphery_writes = var.periphery == null ? [] : [
    {
      path        = "/usr/local/sbin/install-periphery.sh"
      permissions = "0755"
      encoding    = "b64"
      content     = filebase64("${path.module}/files/install-periphery.sh")
    },
    {
      path        = "/etc/systemd/system/komodo-periphery.service"
      permissions = "0644"
      encoding    = "b64"
      content     = filebase64("${path.module}/files/komodo-periphery.service")
    },
    {
      # EnvironmentFile for the oneshot unit. 0600/root because
      # PERIPHERY_PASSKEY is sensitive — same threat model as the cloud-init
      # user-data file already on disk.
      path        = "/etc/komodo-periphery.env"
      permissions = "0600"
      encoding    = "plain"
      content     = "PERIPHERY_VERSION=${var.periphery.version}\nPERIPHERY_PASSKEY=${var.periphery.passkey}\nPERIPHERY_CORE_PUBLIC_KEYS=${var.periphery.core_public_key}\n"
    },
    {
      # Static PKI keypair, mounted by install-periphery.sh at /config/keys.
      # Planting it here means Periphery finds a key already at its default
      # path on first boot and uses it as-is, instead of generating a random
      # one Core has never seen. Matches Core's KOMODO_PERIPHERY_PUBLIC_KEY
      # default — generate your own fleet keypair, don't reuse an example one.
      path        = "/var/lib/komodo-periphery/keys/periphery.key"
      permissions = "0600"
      encoding    = "plain"
      content     = var.periphery.private_key
    },
  ]

  periphery_runs = var.periphery == null ? [] : [
    "systemctl daemon-reload",
    "systemctl enable --now komodo-periphery.service",
  ]

  # Portainer Agent — opt-in. Same self-heal pattern as periphery: oneshot
  # systemd unit re-runs install-portainer-agent.sh on every boot. Exposes
  # this host's Docker daemon on :9001 to a Portainer server elsewhere on the
  # LAN (Environments → Add → Docker Standalone, <static_ipv4>:9001). No
  # secret by default: the agent uses unauthenticated TCP on the LAN; tighten
  # with AGENT_SECRET later if it ever leaves the trust boundary.
  portainer_agent_writes = var.portainer_agent == null ? [] : [
    {
      path        = "/usr/local/sbin/install-portainer-agent.sh"
      permissions = "0755"
      encoding    = "b64"
      content     = filebase64("${path.module}/files/install-portainer-agent.sh")
    },
    {
      path        = "/etc/systemd/system/portainer-agent.service"
      permissions = "0644"
      encoding    = "b64"
      content     = filebase64("${path.module}/files/portainer-agent.service")
    },
    {
      path        = "/etc/portainer-agent.env"
      permissions = "0644"
      encoding    = "plain"
      content     = "PORTAINER_AGENT_VERSION=${var.portainer_agent.version}\n"
    },
  ]

  portainer_agent_runs = var.portainer_agent == null ? [] : [
    "systemctl daemon-reload",
    "systemctl enable --now portainer-agent.service",
  ]

  # Final assembled lists. Caller's writes/runs come LAST so they can read
  # state created by docker/periphery/portainer-agent (e.g. seed config
  # files into a network that's already up).
  all_writes = concat(local.docker_writes, local.docker_networks_writes, local.periphery_writes, local.portainer_agent_writes, var.extra_write_files)
  all_runs   = concat(local.docker_runs, local.docker_networks_runs, local.periphery_runs, local.portainer_agent_runs, var.extra_runcmd)

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname       = var.name
    timezone       = var.timezone
    ssh_public_key = var.admin_ssh_public_key
    base_packages  = local.base_packages
    write_files    = local.all_writes
    runcmd         = local.all_runs
    final_message  = "${var.name} bootstrap complete after $UPTIME seconds"
  })

  # Split into two full yamlencode() calls (rather than one merge() of two
  # differently-shaped objects) because HCL's conditional expression requires
  # both branches to have the SAME structural type — {match=…, set-name=…}
  # vs {} fails "Inconsistent conditional result types" at plan time even
  # though merge() would handle it fine. Each branch here instead resolves to
  # a plain string, which unifies trivially.
  network_config = var.static_ipv4 == null ? "" : (
    var.instance_type == "virtual-machine" ?
    yamlencode({
      version = 2
      ethernets = {
        eth0 = {
          # VMs: match by MAC + rename, since the guest doesn't name it
          # "eth0" on its own (see vm_nic_mac comment above).
          match       = { macaddress = local.vm_nic_mac }
          set-name    = "eth0"
          dhcp4       = false
          addresses   = ["${var.static_ipv4}/${var.static_ipv4_prefix}"]
          routes      = [{ to = "default", via = var.gateway_ipv4 }]
          nameservers = { addresses = var.dns_servers }
        }
      }
      }) : yamlencode({
      version = 2
      ethernets = {
        eth0 = {
          dhcp4       = false
          addresses   = ["${var.static_ipv4}/${var.static_ipv4_prefix}"]
          routes      = [{ to = "default", via = var.gateway_ipv4 }]
          nameservers = { addresses = var.dns_servers }
        }
      }
    })
  )
}

resource "incus_instance" "this" {
  name    = var.name
  image   = var.image
  type    = var.instance_type
  running = true

  config = merge(
    {
      "limits.cpu"           = tostring(var.cpu_cores)
      "limits.memory"        = "${var.memory_mib}MiB"
      "cloud-init.user-data" = local.user_data
      # Native Incus boot behavior: start this instance whenever incusd
      # starts (host boot / daemon restart / NAS OS upgrade). Leaving this
      # false means a host reboot leaves every instance stopped until
      # someone notices and starts them by hand — set true for automatic
      # recovery. Applies to VMs too.
      "boot.autostart" = "true"
    },
    # Container-only privilege/nesting/syscall-intercept knobs. VMs have their
    # own kernel and security model — these keys are invalid on a VM, so only
    # emit them for type = "container".
    var.instance_type == "container" ? {
      "security.privileged"                  = "true"
      "security.nesting"                     = "true"
      "security.syscalls.intercept.mknod"    = "true"
      "security.syscalls.intercept.setxattr" = "true"
      "raw.lxc"                              = "lxc.apparmor.profile = unconfined"
    } : {},
    var.static_ipv4 == null ? {} : {
      "cloud-init.network-config" = local.network_config
    },
  )

  # Bridged NIC on the host's LAN bridge (br0 typically). Replaces the default
  # profile's incusbr0 NAT eth0 — we want the container as a full LAN member.
  device {
    name = "eth0"
    type = "nic"
    properties = merge(
      {
        nictype = "bridged"
        parent  = var.network_bridge
        name    = "eth0"
      },
      # Pin the MAC on VMs only — see local.vm_nic_mac. Leaves every existing
      # container stack's device config byte-for-byte identical (no drift).
      var.instance_type == "virtual-machine" ? { hwaddr = local.vm_nic_mac } : {}
    )
  }

  dynamic "device" {
    for_each = { for d in var.disks : d.name => d }
    content {
      name = device.value.name
      type = "disk"
      properties = {
        source   = device.value.source
        path     = device.value.path
        readonly = "false"
      }
    }
  }

  # Root filesystem. Declared explicitly so `terraform import` of an existing
  # manually-provisioned container reconciles cleanly — without this, TF sees
  # the live root device as not-in-HCL and plans to remove it (which would
  # orphan the container's filesystem).
  device {
    name = "root"
    type = "disk"
    properties = merge(
      {
        path = "/"
        pool = var.root_disk_pool
      },
      # VMs get a fixed-size virtual disk and REQUIRE a size; containers omit it
      # and grow within the ZFS pool. Guarded on null so container stacks (which
      # don't set root_disk_size) render exactly as before — no import churn.
      var.root_disk_size == null ? {} : { size = var.root_disk_size },
    )
  }

  lifecycle {
    # Some NAS "Apps" integrations add config out-of-band (idmap, an
    # autostart mirror). cloud-init.network-config drift is purely a
    # YAML-style difference when adopting a hand-provisioned host (same
    # content, different serializer) — same behavior, no actual change.
    # Ignoring these three lets `terraform plan` come back clean for an
    # imported host without forcing a reverse-engineer of those values into
    # HCL.
    ignore_changes = [
      config["raw.idmap"],
      config["user.autostart"],
      config["cloud-init.network-config"],
    ]
  }
}

############################################
# Re-apply periphery on drift.
#
# cloud-init's runcmd is one-shot: it only fires on first boot. When TF
# updates `cloud-init.user-data` (e.g. periphery version bump or passkey
# rotation) the in-VM state doesn't follow until the next reboot. This
# null_resource closes that gap by re-pushing install-periphery.sh, the
# systemd unit, and the env file, then bouncing the unit so the install
# script re-runs with the new inputs. The script is itself idempotent, so
# re-runs with no diff are no-ops.
#
# Prereq: the machine running terraform must have the `incus` CLI installed
# AND the var.incus_remote remote added & trusted:
#   incus remote add <name> https://<host>:8443 --token=<trust-token>
#
# We use local-exec because there is no provider resource for "execute a
# command inside an Incus instance". This is the *one* place TF can't model
# the operation declaratively — every alternative (cloud-init reboots,
# manual SSH) is worse.
############################################
resource "null_resource" "reapply_periphery" {
  count = var.periphery == null ? 0 : 1

  triggers = {
    instance_name     = incus_instance.this.name
    incus_remote      = var.incus_remote
    script_hash       = filemd5("${path.module}/files/install-periphery.sh")
    unit_hash         = filemd5("${path.module}/files/komodo-periphery.service")
    periphery_version = var.periphery.version
    # Hash the passkey/private_key so triggers don't expose them in plan output.
    periphery_passkey     = sha256(var.periphery.passkey)
    periphery_private_key = sha256(var.periphery.private_key)
    core_public_key       = sha256(var.periphery.core_public_key)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      INCUS_REMOTE               = var.incus_remote
      INSTANCE                   = incus_instance.this.name
      SCRIPT_PATH                = "${path.module}/files/install-periphery.sh"
      UNIT_PATH                  = "${path.module}/files/komodo-periphery.service"
      PERIPHERY_VERSION          = var.periphery.version
      PERIPHERY_PASSKEY          = var.periphery.passkey
      PERIPHERY_PRIVATE_KEY      = var.periphery.private_key
      PERIPHERY_CORE_PUBLIC_KEYS = var.periphery.core_public_key
    }
    command = <<-EOT
      set -euo pipefail
      target="$INCUS_REMOTE:$INSTANCE"
      # VMs need their in-guest agent up before `incus exec` works at all.
      for i in $(seq 1 60); do
        incus exec "$target" -- true 2>/dev/null && break
        sleep 2
      done
      # incus reports the instance "created" as soon as it's running — but
      # cloud-init (which installs docker) may still be going. Block here
      # until cloud-init completes, otherwise the script below hits
      # `docker: command not found`.
      incus exec "$target" -- cloud-init status --wait
      incus file push "$SCRIPT_PATH" "$target/usr/local/sbin/install-periphery.sh" --mode=0755
      incus file push "$UNIT_PATH" "$target/etc/systemd/system/komodo-periphery.service" --mode=0644
      # Rewrite the env file so version/passkey rotations land. stdin push
      # avoids the passkey ever hitting a tempfile on the runner.
      printf 'PERIPHERY_VERSION=%s\nPERIPHERY_PASSKEY=%s\nPERIPHERY_CORE_PUBLIC_KEYS=%s\n' \
        "$PERIPHERY_VERSION" "$PERIPHERY_PASSKEY" "$PERIPHERY_CORE_PUBLIC_KEYS" \
        | incus file push - "$target/etc/komodo-periphery.env" --mode=0600
      # Re-plant the static keypair on every drift-repair too, so it can't
      # silently diverge from the fleet default even if something on the VM
      # ever touched it.
      incus exec "$target" -- mkdir -p /var/lib/komodo-periphery/keys
      printf '%s' "$PERIPHERY_PRIVATE_KEY" \
        | incus file push - "$target/var/lib/komodo-periphery/keys/periphery.key" --mode=0600
      incus exec "$target" -- systemctl daemon-reload
      incus exec "$target" -- systemctl enable komodo-periphery.service
      # restart (not start) so the oneshot re-runs even when RemainAfterExit
      # has it sitting in active(exited).
      incus exec "$target" -- systemctl restart komodo-periphery.service
    EOT
  }
}

############################################
# Re-apply docker networks on drift.
#
# Same rationale as reapply_periphery: cloud-init's runcmd is one-shot, so a
# change to var.docker_networks (or to the script/unit) needs to be pushed
# directly. The script is itself idempotent — adding a new name creates it,
# names already present are no-ops, and removed names are NOT torn down
# (avoid surprising disconnects of running containers).
############################################
resource "null_resource" "apply_docker_networks" {
  count = (var.install_docker && length(var.docker_networks) > 0) ? 1 : 0

  triggers = {
    instance_name   = incus_instance.this.name
    incus_remote    = var.incus_remote
    script_hash     = filemd5("${path.module}/files/ensure-docker-networks.sh")
    unit_hash       = filemd5("${path.module}/files/docker-networks.service")
    docker_networks = join(" ", var.docker_networks)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      INCUS_REMOTE    = var.incus_remote
      INSTANCE        = incus_instance.this.name
      SCRIPT_PATH     = "${path.module}/files/ensure-docker-networks.sh"
      UNIT_PATH       = "${path.module}/files/docker-networks.service"
      DOCKER_NETWORKS = join(" ", var.docker_networks)
    }
    command = <<-EOT
      set -euo pipefail
      target="$INCUS_REMOTE:$INSTANCE"
      for i in $(seq 1 60); do
        incus exec "$target" -- true 2>/dev/null && break
        sleep 2
      done
      incus exec "$target" -- cloud-init status --wait
      incus file push "$SCRIPT_PATH" "$target/usr/local/sbin/ensure-docker-networks.sh" --mode=0755
      incus file push "$UNIT_PATH" "$target/etc/systemd/system/docker-networks.service" --mode=0644
      printf 'DOCKER_NETWORKS="%s"\n' "$DOCKER_NETWORKS" \
        | incus file push - "$target/etc/docker-networks.env" --mode=0644
      incus exec "$target" -- systemctl daemon-reload
      incus exec "$target" -- systemctl enable docker-networks.service
      incus exec "$target" -- systemctl restart docker-networks.service
    EOT
  }
}

############################################
# Re-apply base_packages on drift.
#
# Closes the gap that cloud-init's `packages:` block leaves: cloud-init
# runs once on first boot and never reads its package list again, so
# adding a new entry to local.base_packages would otherwise sit inert on
# already-running hosts until they're recreated. This null_resource runs
# `apt-get install -y` on every apply where the joined-package-list hash
# changes, making package additions propagate the same way docker networks
# and the periphery / portainer-agent containers already do.
#
# Idempotency: apt-get install -y is a no-op for already-installed
# packages. Removed packages are NOT purged (symmetric with the other
# null_resources in this file).
############################################
resource "null_resource" "apply_packages" {
  count = length(local.base_packages) > 0 ? 1 : 0

  triggers = {
    instance_name = incus_instance.this.name
    incus_remote  = var.incus_remote
    packages      = join(" ", local.base_packages)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      INCUS_REMOTE = var.incus_remote
      INSTANCE     = incus_instance.this.name
      PACKAGES     = join(" ", local.base_packages)
    }
    command = <<-EOT
      set -euo pipefail
      target="$INCUS_REMOTE:$INSTANCE"
      # VMs need their in-guest agent to boot before `incus exec` works at
      # all; containers don't (namespace-based exec), so this loop is a
      # fast no-op for them.
      for i in $(seq 1 60); do
        incus exec "$target" -- true 2>/dev/null && break
        sleep 2
      done
      # Wait for cloud-init: on a fresh host the apt lock is held while
      # cloud-init's own package install runs, so apt-get update would
      # fight it. On an existing host this returns "done" immediately.
      incus exec "$target" -- cloud-init status --wait
      incus exec "$target" -- env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      incus exec "$target" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PACKAGES
    EOT
  }
}

############################################
# Re-apply portainer-agent on drift. Same self-heal pattern as periphery.
############################################
resource "null_resource" "reapply_portainer_agent" {
  count = var.portainer_agent == null ? 0 : 1

  triggers = {
    instance_name           = incus_instance.this.name
    incus_remote            = var.incus_remote
    script_hash             = filemd5("${path.module}/files/install-portainer-agent.sh")
    unit_hash               = filemd5("${path.module}/files/portainer-agent.service")
    portainer_agent_version = var.portainer_agent.version
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      INCUS_REMOTE            = var.incus_remote
      INSTANCE                = incus_instance.this.name
      SCRIPT_PATH             = "${path.module}/files/install-portainer-agent.sh"
      UNIT_PATH               = "${path.module}/files/portainer-agent.service"
      PORTAINER_AGENT_VERSION = var.portainer_agent.version
    }
    command = <<-EOT
      set -euo pipefail
      target="$INCUS_REMOTE:$INSTANCE"
      for i in $(seq 1 60); do
        incus exec "$target" -- true 2>/dev/null && break
        sleep 2
      done
      incus exec "$target" -- cloud-init status --wait
      incus file push "$SCRIPT_PATH" "$target/usr/local/sbin/install-portainer-agent.sh" --mode=0755
      incus file push "$UNIT_PATH" "$target/etc/systemd/system/portainer-agent.service" --mode=0644
      printf 'PORTAINER_AGENT_VERSION=%s\n' "$PORTAINER_AGENT_VERSION" \
        | incus file push - "$target/etc/portainer-agent.env" --mode=0644
      incus exec "$target" -- systemctl daemon-reload
      incus exec "$target" -- systemctl enable portainer-agent.service
      incus exec "$target" -- systemctl restart portainer-agent.service
    EOT
  }
}
