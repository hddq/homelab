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
  account_id = data.sops_file.secrets.data["cloudflare_account_id"]
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

# GitHub Pages: frc.hddq.org
resource "cloudflare_dns_record" "frc_github_pages" {
  zone_id = local.zone_id
  name    = "frc"
  type    = "CNAME"
  content = "hddq.github.io"
  ttl     = 1
  proxied = false
}

# Email Routing: hddq.org
resource "cloudflare_dns_record" "mx1" {
  zone_id  = local.zone_id
  name     = "hddq.org"
  type     = "MX"
  content  = "route1.mx.cloudflare.net"
  priority = 14
  ttl      = 1
}

resource "cloudflare_dns_record" "mx2" {
  zone_id  = local.zone_id
  name     = "hddq.org"
  type     = "MX"
  content  = "route2.mx.cloudflare.net"
  priority = 28
  ttl      = 1
}

resource "cloudflare_dns_record" "mx3" {
  zone_id  = local.zone_id
  name     = "hddq.org"
  type     = "MX"
  content  = "route3.mx.cloudflare.net"
  priority = 7
  ttl      = 1
}

resource "cloudflare_dns_record" "spf" {
  zone_id = local.zone_id
  name    = "hddq.org"
  type    = "TXT"
  content = "v=spf1 include:_spf.mx.cloudflare.net ~all"
  ttl     = 1
}

resource "cloudflare_dns_record" "dkim" {
  zone_id = local.zone_id
  name    = "cf2024-1._domainkey.hddq.org"
  type    = "TXT"
  content = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78km4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB"
  ttl     = 1
}

resource "cloudflare_dns_record" "dmarc" {
  zone_id = local.zone_id
  name    = "_dmarc"
  type    = "TXT"
  content = "v=DMARC1; p=reject;"
  ttl     = 1
}

resource "cloudflare_email_routing_address" "my_gmail" {
  account_id = local.account_id
  email      = "hddqgit@gmail.com"
}

resource "cloudflare_email_routing_rule" "git_forward" {
  zone_id = local.zone_id
  name    = "Redirect Git"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = "git@hddq.org"
  }]

  actions = [{
    type  = "forward"
    value = [cloudflare_email_routing_address.my_gmail.email]
  }]
}
