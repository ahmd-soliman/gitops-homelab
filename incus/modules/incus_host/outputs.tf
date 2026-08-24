output "name" {
  value = incus_instance.this.name
}

output "ipv4_address" {
  description = "Static IP if configured, else null (look up via incus list when DHCP)."
  value       = var.static_ipv4
}

output "ssh_command" {
  description = "Convenience: ssh hint for poking at the container."
  value       = var.static_ipv4 == null ? "incus exec ${var.name} -- bash" : "ssh ubuntu@${var.static_ipv4}"
}
