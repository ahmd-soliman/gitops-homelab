terraform {
  required_version = ">= 1.5"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  # Token via TF_VAR_cloudflare_api_token — never hardcode. Needs:
  #   Zone:Read + DNS:Edit, scoped to your zone only.
  api_token = var.cloudflare_api_token
}
