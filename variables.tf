variable "proxmox_endpoint" {
  description = "Адрес API Proxmox"
  type        = string
  default     = "https://192.168.91.101:8006/"
}

variable "proxmox_api_token" {
  description = "Токен вида terraform@pve!tf=<uuid>. Передавать через TF_VAR_proxmox_api_token"
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
  description = "ISO Talos, уже лежащий в хранилище Proxmox"
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
  description = "Строка installer image с factory.talos.dev"
  type        = string
}

variable "nodes" {
  description = "Ноды кластера. MAC задаётся явно, чтобы совпадал с арендой на роутере"
  type = map(object({
    role    = string # controlplane | worker
    vmid    = number
    ip      = string
    mac     = string
    cores   = number
    memory  = number # МБ
    disk_gb = optional(number, 20)
  }))

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) == 1
    error_message = "Нужна ровно одна нода с role = controlplane."
  }
}
