terraform {
  required_version = ">= 1.5"

  required_providers {
    truenas = {
      source  = "bmanojlovic/truenas"
      version = "~> 0.0.34"
    }
  }
}

provider "truenas" {
  # The provider builds `wss://{host}/websocket` itself, so `host` is a
  # "hostname:port" LITERAL, not a URL (passing https://… yields
  # `wss://https://…` and fails). Port 8443 = the TrueNAS WebUI/API.
  #
  # LAN-ONLY: this only resolves inside your network, so this stack can only
  # run from a LAN-attached runner or a LAN machine — not a SaaS CI runner.
  host  = "${var.truenas_host}:8443"
  token = var.truenas_api_token
}
