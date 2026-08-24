variable "name" {
  description = "Incus instance name. Becomes hostname."
  type        = string
}

variable "incus_remote" {
  description = "Name of the local `incus` CLI remote that points at the same target as the provider. Used by the drift-reapply null_resource. Match the provider's remote { name = ... }."
  type        = string
  default     = "homelab"
}

variable "image" {
  description = "Incus image alias (must be the cloud variant — has cloud-init preinstalled). Prefix with `images:` so incus pulls from the public images server on first use; subsequent creates hit the local cache."
  type        = string
  default     = "images:ubuntu/24.04/cloud"
}

variable "instance_type" {
  description = "Incus instance type: \"container\" (LXC system container, shares the host kernel) or \"virtual-machine\" (KVM/QEMU, own kernel). VMs are required for real kubelet/containerd/etcd workloads — a kubelet can't run cleanly in a shared-kernel container. Changing this forces instance replacement. Host prereq for VMs: /dev/kvm present and the incus qemu driver available."
  type        = string
  default     = "container"
  validation {
    condition     = contains(["container", "virtual-machine"], var.instance_type)
    error_message = "instance_type must be \"container\" or \"virtual-machine\"."
  }
}

variable "root_disk_size" {
  description = "Root disk size, e.g. \"40GiB\". REQUIRED for virtual-machine instances (a VM gets a fixed-size virtual disk). Leave null for containers — they grow within the ZFS pool and don't take a size property."
  type        = string
  default     = null
}

variable "cpu_cores" {
  type    = number
  default = 4
}

variable "memory_mib" {
  type    = number
  default = 8192
}

variable "timezone" {
  type    = string
  default = "UTC"
}

variable "admin_ssh_public_key" {
  description = "Public key seeded into the ubuntu user via cloud-init."
  type        = string
}

variable "network_bridge" {
  description = "Linux bridge on the host that this container's eth0 attaches to (BRIDGED mode)."
  type        = string
  default     = "br0"
}

variable "static_ipv4" {
  description = "Static IPv4 (no prefix). null → DHCP."
  type        = string
  default     = null
}

variable "static_ipv4_prefix" {
  type    = number
  default = 24
}

variable "gateway_ipv4" {
  type    = string
  default = null
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "8.8.8.8"]
}

variable "disks" {
  description = "Bind-mount disk devices to attach. Each {name, source (host path), path (guest path)}."
  type = list(object({
    name   = string
    source = string
    path   = string
  }))
  default = []
}

variable "root_disk_pool" {
  description = "ZFS pool that backs the container's root filesystem. Declared explicitly here (not inherited from the default profile) so `terraform import` of a bash-provisioned container doesn't see the live root disk as a no-op-removed device."
  type        = string
  default     = "tank"
}

variable "install_docker" {
  description = "Install docker-ce via the official apt repo, plus create var.docker_networks."
  type        = bool
  default     = true
}

variable "docker_networks" {
  description = "Named docker networks to create on first boot (only used when install_docker = true)."
  type        = list(string)
  default     = []
}

variable "periphery" {
  description = "Komodo Periphery install. null → don't install. Set to register the host with Komodo Core. private_key is a static PKI keypair (PEM) shared across the whole fleet, matching Core's KOMODO_PERIPHERY_PUBLIC_KEY default — lets Core trust this Periphery without per-server onboarding. Generate your own fleet keypair; do not reuse an example one."
  type = object({
    version         = string
    passkey         = string
    private_key     = string
    core_public_key = string
  })
  default   = null
  sensitive = true
}

variable "portainer_agent" {
  description = "Portainer Agent install. null → don't install. Set to register the host with Portainer on the NAS (Environments → Add → Docker Standalone, address <ip>:9001)."
  type = object({
    version = string
  })
  default = null
}

variable "extra_write_files" {
  description = "Per-host cloud-init write_files entries. Each {path, content (or content_b64), permissions, encoding}. Encoding 'b64' means content is base64."
  type = list(object({
    path        = string
    content     = string
    permissions = string
    encoding    = string
  }))
  default = []
}

variable "extra_runcmd" {
  description = "Per-host cloud-init runcmd entries. Each is a shell string. Runs after docker + periphery, in order."
  type        = list(string)
  default     = []
}
