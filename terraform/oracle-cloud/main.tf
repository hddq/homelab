terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.22.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "1.4.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.0"
    }
  }
}

data "sops_file" "secrets" {
  source_file = "secrets.yaml"
}

locals {
  tenancy_ocid     = data.sops_file.secrets.data["tenancy_ocid"]
  user_ocid        = data.sops_file.secrets.data["user_ocid"]
  fingerprint      = data.sops_file.secrets.data["fingerprint"]
  private_key_path = data.sops_file.secrets.data["private_key_path"]
  region           = data.sops_file.secrets.data["region"]
  compartment_ocid = data.sops_file.secrets.data["compartment_ocid"]
  ssh_public_key   = data.sops_file.secrets.data["ssh_public_key"]
}

provider "oci" {
  tenancy_ocid     = local.tenancy_ocid
  user_ocid        = local.user_ocid
  fingerprint      = local.fingerprint
  private_key_path = local.private_key_path
  region           = local.region
}

# Get available availability domains in the tenancy
data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

# Create a Virtual Cloud Network (VCN)
resource "oci_core_vcn" "free_vcn" {
  compartment_id = local.compartment_ocid
  cidr_block     = "192.168.70.0/24"
  display_name   = "always-free-vcn"
  dns_label      = "freevcn"
}

# Create an Internet Gateway
resource "oci_core_internet_gateway" "free_igw" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "always-free-igw"
}

# Create a Route Table
resource "oci_core_route_table" "free_rt" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "always-free-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.free_igw.id
  }
}

# Create a Security List to allow SSH (port 22) and ICMP
resource "oci_core_security_list" "free_sl" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.free_vcn.id
  display_name   = "always-free-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      max = 22
      min = 22
    }
  }

  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "10.0.0.0/16"
    icmp_options {
      type = 3
    }
  }
}

# Create a Subnet
resource "oci_core_subnet" "free_subnet" {
  compartment_id    = local.compartment_ocid
  vcn_id            = oci_core_vcn.free_vcn.id
  cidr_block        = "192.168.70.0/24"
  display_name      = "always-free-subnet"
  route_table_id    = oci_core_route_table.free_rt.id
  security_list_ids = [oci_core_security_list.free_sl.id]
}

# Get latest Ubuntu 24.04 image for ARM
data "oci_core_images" "ubuntu_images" {
  compartment_id           = local.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Create the Always Free Compute Instance
resource "oci_core_instance" "free_instance" {
  # Change the index [0] if the first availability domain doesn't have free capacity
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.compartment_ocid
  display_name        = "vps0"

  # Ampere A1 (ARM) Always Free shape
  shape = "VM.Standard.A1.Flex"

  # Always Free A1 limit is a total of 2 OCPUs and 12GB of RAM across the tenancy
  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.free_subnet.id
    assign_public_ip = true
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_images.images[0].id

    # 200GB is the max free tier total block volume storage
    boot_volume_size_in_gbs = 200
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
  }

  # Prevent Terraform from destroying and recreating on certain changes
  lifecycle {
    ignore_changes = [
      source_details[0].source_id
    ]
  }
}

# Automatically deploy NixOS on the new instance
resource "null_resource" "install_nixos" {
  # Re-run if the instance is recreated
  triggers = {
    instance_id = oci_core_instance.free_instance.id
  }

  provisioner "local-exec" {
    # We wait a bit for Ubuntu to fully boot and start sshd, 
    # then run nixos-anywhere from the local machine.
    # Adjust sleep time if your instance takes longer to boot.
    command = <<EOT
      echo "Waiting 60 seconds for Ubuntu to boot and start SSH..."
      sleep 60
      # Ensure you run tofu apply from within the terraform/oracle-cloud directory
      # so the relative path to the flake resolves correctly.
      nix run github:nix-community/nixos-anywhere -- --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null --flake ../../nix/vps0#vps0 ubuntu@${oci_core_instance.free_instance.public_ip}
    EOT
  }
}
