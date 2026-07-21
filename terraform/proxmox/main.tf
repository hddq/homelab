resource "proxmox_virtual_environment_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_file {
    path      = "https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.13.6/nocloud-amd64.iso"
    file_name = "talos-v1.13.6-nocloud-amd64.iso"
  }
}

resource "proxmox_virtual_environment_vm" "talos_staging" {
  name        = "k8s-staging-1"
  description = "Talos staging control plane"
  tags        = ["talos", "k8s", "staging"]
  node_name   = var.proxmox_node
  vm_id       = 220

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 6144
    floating  = 4096
  }

  agent {
    enabled = true
  }

  on_boot = false

  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id = "local-zfs"
    file_format  = "raw"
    type         = "4m"
  }

  # Main OS disk
  disk {
    datastore_id = "local-zfs"
    file_format  = "raw"
    interface    = "virtio0"
    size         = 20
    ssd          = true
    iothread     = true
    discard      = "on"
  }
  # PVC Disk
  disk {
    datastore_id = "local-zfs"
    file_format  = "raw"
    interface    = "virtio1"
    size         = 20
    ssd          = true
    iothread     = true
    discard      = "on"
  }

  cdrom {
    file_id   = proxmox_virtual_environment_file.talos_iso.id
    interface = "ide2"
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 20
  }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide3"
    ip_config {
      ipv4 {
        address = "192.168.20.120/24"
        gateway = "192.168.20.1"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["virtio0", "ide2"]
}
