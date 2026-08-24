variable "truenas_host" {
  description = "TrueNAS host (hostname or IP, no scheme/port). The :8443 API port is appended in the provider."
  type        = string
  default     = "nas.homelab.example"
}

variable "truenas_api_token" {
  description = "TrueNAS API key (Credentials > Local Users > API Keys). Pass via TF_VAR_truenas_api_token — never commit."
  type        = string
  sensitive   = true
}
