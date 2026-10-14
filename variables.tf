variable "proxmox_endpoint" {
  description = "Proxmox API address"
  type        = string
  default     = "https://192.168.91.101:8006/"
}

variable "proxmox_api_token" {
  description = "Token of the form terraform@pve!tf=<uuid>. Pass it through TF_VAR_proxmox_api_token"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  type    = string
  default = "pve"
}

variable "vm_datastore" {
  type    = string
  default = "local-lvm"
}

variable "talos_iso" {
  description = "Talos ISO already uploaded to the Proxmox storage"
  type        = string
  default     = "local:iso/talos.iso"
}

variable "cluster_name" {
  type    = string
  default = "lab"
}

variable "talos_version" {
  type    = string
  default = "v1.14.2"
}

variable "talos_installer_image" {
  description = "Installer image string from factory.talos.dev"
  type        = string
}

variable "nodes" {
  description = "Cluster nodes. The MAC is set explicitly so that it matches the lease on the router"
  type = map(object({
    role    = string # controlplane | worker
    vmid    = number
    ip      = string
    mac     = string
    cores   = number
    memory  = number # MB
    disk_gb = optional(number, 20)
  }))

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) == 1
    error_message = "Exactly one node with role = controlplane is required."
  }
}
