terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.21.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "1.4.1"
    }
  }
}

data "sops_file" "secrets" {
  source_file = "secrets.yaml"
}

provider "cloudflare" {
  # Inject the decrypted token into the Cloudflare provider
  api_token = data.sops_file.secrets.data["cloudflare_api_token"]
}

data "cloudflare_zones" "my_domain" {
  name = "hddq.org"
}

output "zone_id" {
  value       = data.cloudflare_zones.my_domain.result[0].id
  description = "The Cloudflare Zone ID for the domain"
}

locals {
  zone_id = data.cloudflare_zones.my_domain.result[0].id
}

# Production: *.lab.hddq.org → 192.168.41.10 (Traefik)
resource "cloudflare_dns_record" "lab_apex" {
  zone_id = local.zone_id
  name    = "lab"
  type    = "A"
  content = "192.168.41.10"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "lab_wildcard" {
  zone_id = local.zone_id
  name    = "*.lab"
  type    = "A"
  content = "192.168.41.10"
  ttl     = 1
  proxied = false
}

# Staging: *.stg.hddq.org → 192.168.42.10 (Traefik)
resource "cloudflare_dns_record" "stg_apex" {
  zone_id = local.zone_id
  name    = "stg"
  type    = "A"
  content = "192.168.42.10"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "stg_wildcard" {
  zone_id = local.zone_id
  name    = "*.stg"
  type    = "A"
  content = "192.168.42.10"
  ttl     = 1
  proxied = false
}
