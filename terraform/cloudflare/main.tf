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
