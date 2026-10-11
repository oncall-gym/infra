terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # самоподписанный сертификат Proxmox
}

locals {
  # Адрес первой (и пока единственной) управляющей ноды
  cp_ip = one([for n in var.nodes : n.ip if n.role == "controlplane"])
}

# ---------- Виртуальные машины ----------

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  node_name = var.proxmox_node
  vm_id     = each.value.vmid
  name      = "talos-${each.key}"
  tags      = ["talos", "terraform"]

  on_boot         = true
  stop_on_destroy = true
  scsi_hardware   = "virtio-scsi-single"
  boot_order      = ["scsi0", "ide3"]

  # UEFI вместо SeaBIOS: Talos в этом режиме ставит systemd-boot
  # и не вызывает grub-install, на котором установка зависала.
  bios = "ovmf"

  efi_disk {
    datastore_id      = var.vm_datastore
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false # без ключей Secure Boot, образ Talos обычный
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # В образе Talos есть расширение qemu-guest-agent: без устройства агента
  # его служба не стартует, и нода навсегда остаётся в стадии Booting.
  agent {
    enabled = true
    timeout = "2m"
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_gb
    file_format  = "raw"
  }

  cdrom {
    file_id   = var.talos_iso
    interface = "ide3"
  }

  operating_system {
    type = "l26"
  }
}

# ---------- Talos ----------

# Секреты кластера: сертификаты, ключи, токены. Хранятся в state.
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.cp_ip}:6443"
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = concat([
    # С Talos 1.14 установка описывается отдельным документом,
    # а не полем machine.install.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      reboot     = true # перезагрузиться с диска после установки
      installer = {
        image = var.talos_installer_image
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"/dev/sda\""
        }
        wipe = true
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = "talos-${each.key}"
      auto       = "off"
    }),
    ],
    # Cilium вместо встроенных Flannel и kube-proxy. Это настройки кластера,
    # поэтому они идут только в конфигурацию управляющей ноды.
    each.value.role == "controlplane" ? [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeFlannelCNIConfig"
        "$patch"   = "delete"
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeProxyConfig"
        enabled    = false
      }),
      # Поды из namespace talos-backup могут снимать снимки etcd через Talos API, и больше ничего
      yamlencode({
        apiVersion                  = "v1alpha1"
        kind                        = "KubeTalosAPIAccessConfig"
        allowedRoles                = ["os:etcd:backup"]
        allowedKubernetesNamespaces = ["talos-backup"]
      }),
    ] : []
  )
}

# Аналог `talosctl apply-config --insecure`
resource "talos_machine_configuration_apply" "node" {
  for_each   = var.nodes
  depends_on = [proxmox_virtual_environment_vm.node]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip
}

# Аналог `talosctl bootstrap`
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.node]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip
}

# Аналог `talosctl kubeconfig`
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.cp_ip]
  nodes                = [local.cp_ip]
}
