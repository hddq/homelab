locals {
  talos_versions = yamldecode(file("${path.module}/../../talos/versions.yaml"))

  talos_nodes = {
    staging-cp-1 = {
      name        = "k8s-staging-1"
      description = "Talos staging control plane"
      environment = "staging"
      role        = "control-plane"
      vm_id       = 499
      ip_address  = "192.168.20.120"
      cpu_cores   = 4
      memory      = 6144
      balloon     = 4096
    }
    production-cp-1 = {
      name        = "k8s-prod-cp-1"
      description = "Talos production control plane"
      environment = "production"
      role        = "control-plane"
      vm_id       = 400
      ip_address  = "192.168.20.100"
      cpu_cores   = 6
      memory      = 8192
      balloon     = 6144
    }
    production-worker-1 = {
      name        = "k8s-prod-worker-1"
      description = "Talos production worker"
      environment = "production"
      role        = "worker"
      vm_id       = 401
      ip_address  = "192.168.20.101"
      cpu_cores   = 4
      memory      = 8192
      balloon     = 6144
    }
  }
}

resource "proxmox_virtual_environment_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_file {
    path      = "https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/${local.talos_versions.TALOS_VERSION}/nocloud-amd64.iso"
    file_name = "talos-${local.talos_versions.TALOS_VERSION}-nocloud-amd64.iso"
  }
}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.talos_nodes

  name        = each.value.name
  description = each.value.description
  tags        = ["talos", "k8s", each.value.environment, each.value.role]
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id

  cpu {
    cores = each.value.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = each.value.balloon
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
        address = "${each.value.ip_address}/24"
        gateway = "192.168.20.1"
      }
    }
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["virtio0", "ide2"]
}
