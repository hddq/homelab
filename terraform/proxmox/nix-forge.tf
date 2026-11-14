resource "proxmox_download_file" "debian_trixie_cloud_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "z690"
  url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name    = "debian-13-genericcloud-amd64.qcow2"

  lifecycle {
    ignore_changes = [
      url,
    ]
  }
}

resource "proxmox_virtual_environment_vm" "nix_forge" {
  name            = "nix-forge"
  description     = "NixOS forge VM"
  tags            = ["nixos", "forge"]
  node_name       = "z690"
  vm_id           = 900
  stop_on_destroy = true
  on_boot         = true

  lifecycle {
    ignore_changes = [
      started,
      disk[0].import_from,
      initialization,
    ]
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 6144
    floating  = 6144
  }

  # Disabled during initial Debian cloud-image bootstrap so apply does not wait
  # for qemu-guest-agent before nixos-anywhere replaces the OS.
  agent {
    enabled = false
  }

  serial_device {}

  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id = "local-zfs"
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = "local-zfs"
    import_from  = proxmox_download_file.debian_trixie_cloud_image.id
    file_format  = "raw"
    interface    = "scsi0"
    size         = 64
    iothread     = false
    discard      = "on"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 20
  }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide3"

    dns {
      servers = ["192.168.41.13", "192.168.70.2"]
    }

    ip_config {
      ipv4 {
        address = "192.168.20.18/24"
        gateway = "192.168.20.1"
      }
    }

    user_account {
      username = "debian"
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKFgv0ykKB0lLGjkh3fI8tUy+o8qtUcgjFPSN1AyncW hddq@main",
      ]
    }
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["scsi0"]
}

resource "terraform_data" "install_nix_forge" {
  triggers_replace = [
    proxmox_virtual_environment_vm.nix_forge.id,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Debian to boot and start SSH on 192.168.20.18..."
      for i in $(seq 1 60); do
        if ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null debian@192.168.20.18 true 2>/dev/null; then
          break
        fi
        sleep 5
      done
      # Run tofu apply from within terraform/proxmox so the relative flake path resolves.
      nix run github:nix-community/nixos-anywhere -- \
        --ssh-option StrictHostKeyChecking=no \
        --ssh-option UserKnownHostsFile=/dev/null \
        --flake ../../nix/forge#forge \
        debian@192.168.20.18
    EOT
  }
}
