variable "cloudflare_api_token" {
  description = "Cloudflare API token, scoped Zone:Read + DNS:Edit on your zone only. Pass via TF_VAR_cloudflare_api_token."
  type        = string
  sensitive   = true
}

variable "zone_name" {
  description = "The Cloudflare zone to manage."
  type        = string
  default     = "homelab.example"
}
