# Remote-managed Terraform state — same pattern as terraform/dns.
terraform {
  backend "http" {}
}
