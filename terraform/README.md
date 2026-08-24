# Terraform Configurations

This directory contains the declarative infrastructure configurations for managing homelab resources outside of individual application stacks.

It is split into two configurations:
* **[`dns/`](dns/)** — Configures Cloudflare DNS records (CNAME mappings proxying traffic back to Caddy at the LAN edge).
* **[`truenas/`](truenas/)** — Configures ZFS datasets on the TrueNAS pool using the TrueNAS provider to back persistent application config volumes.

---

## ☁️ Cloudflare DNS as Code (`dns`)

Manages your Cloudflare DNS zone records declaratively.

### Two records Terraform must NEVER manage
Both are owned dynamically by other tools; managing them here would cause conflicts:
1. **`_acme-challenge.*` TXT** — Caddy creates and deletes these dynamically during ACME DNS-01 certificate issuance.
2. **Dynamic-DNS record** — If you run a dynamic DNS updater (like `apps/ddns-updater`), it will write your dynamic public IP into the apex `@` A record or a dedicated origin record.

When you import your existing zone, make sure to delete these record blocks from your generated config before applying.

### Setup and Initialization
This directory uses a generic **HTTP remote backend** (declared in `backend.tf`) to manage state remotely. Example using GitLab's HTTP state backend:

```bash
cd terraform/dns
PROJECT_ID=<numeric-project-id>
STATE_NAME=homelab-dns
terraform init \
  -backend-config="address=https://gitlab.com/api/v4/projects/${PROJECT_ID}/terraform/state/${STATE_NAME}" \
  -backend-config="lock_address=https://gitlab.com/api/v4/projects/${PROJECT_ID}/terraform/state/${STATE_NAME}/lock" \
  -backend-config="unlock_address=https://gitlab.com/api/v4/projects/${PROJECT_ID}/terraform/state/${STATE_NAME}/lock" \
  -backend-config="username=<gitlab-user>" \
  -backend-config="password=<PAT>" \
  -backend-config="lock_method=POST" \
  -backend-config="unlock_method=DELETE" \
  -backend-config="retry_wait_min=5"
```
*(If you prefer local state, replace `backend.tf` with `backend "local" {}` and ensure `*.tfstate` is gitignored.)*

### Import and Reconcile
Always adopt existing DNS records first rather than recreating them:
```bash
export CLOUDFLARE_API_TOKEN=<Zone:Read + DNS:Edit token>
ZONE_ID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=homelab.example" | jq -r '.result[0].id')

# Generate accurate resource blocks from the live zone:
cf-terraforming generate --resource-type cloudflare_record --zone "$ZONE_ID" > generated.tf

# Generate matching import commands:
cf-terraforming import --resource-type cloudflare_record --zone "$ZONE_ID" > import.sh
```
1. Open `generated.tf` and delete the excluded TXT and A/AAAA DDNS records. Copy the rest into `records.tf`.
2. Run `import.sh` to load the current state.
3. Run `terraform plan` and confirm there is a **zero-diff** before running `terraform apply`.

---

## 💾 TrueNAS ZFS Datasets (`truenas`)

Manages `tank/app-config/*` ZFS datasets on a TrueNAS NAS via the `bmanojlovic/truenas` provider.

### ⚠️ LAN-only Restriction
The TrueNAS API runs on a LAN address. Therefore, this state **cannot be applied from a SaaS CI runner**—it must be run from a local machine or a LAN-attached runner.

### Usage
```bash
cd terraform/truenas
export TF_VAR_truenas_api_token='<TrueNAS API key>'   # WebUI > Local Users > API Keys

# Initialize using backend configs (see dns configs above for format):
terraform init ...
terraform plan
terraform apply
```

### Import Existing Datasets
```bash
# Add the name to local.datasets in datasets.tf, then run:
terraform import 'truenas_pool_dataset.ds["tank/app-config/grafana"]' tank/app-config/grafana
terraform plan      # reconcile to zero-diff before apply
```
