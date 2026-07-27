variable "proxmox_endpoint" {
  type        = string
  description = "The endpoint for the Proxmox API (e.g., https://192.168.20.10:8006/)"
  default     = "https://192.168.20.10:8006/"
}

variable "proxmox_node" {
  type        = string
  description = "The name of the Proxmox node to deploy to"
  default     = "z690"
}
