# Remote-managed Terraform state (e.g. GitLab's HTTP backend, or Terraform
# Cloud) — state config is supplied at `terraform init` time so nothing
# secret lands in git. See README.md "First-time init".
#
# Prefer a remote backend over local state: DNS is applied infrequently and
# possibly from more than one machine, and locking + a durable remote copy
# prevents a lost laptop from losing the zone's state.
terraform {
  backend "http" {}
}
