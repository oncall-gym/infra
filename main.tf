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
  insecure  = true # Proxmox uses a self-signed certificate
}

locals {
  # Address of the first (and so far the only) control plane node
  cp_ip = one([for n in var.nodes : n.ip if n.role == "controlplane"])
}

# ---------- Virtual machines ----------

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

  # UEFI instead of SeaBIOS: in this mode Talos installs systemd-boot
  # and does not call grub-install, where the installation used to hang.
  bios = "ovmf"

  efi_disk {
    datastore_id      = var.vm_datastore
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false # no Secure Boot keys, the Talos image is a regular one
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # The Talos image includes the qemu-guest-agent extension: without the agent device
  # its service does not start, and the node stays in the Booting stage forever.
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

# Cluster secrets: certificates, keys, tokens. Stored in the state.
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
    # Since Talos 1.14 the installation is described by a separate document,
    # not by the machine.install field.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      reboot     = true # reboot from disk after the installation
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
    # Cilium instead of the built-in Flannel and kube-proxy. These are cluster settings,
    # so they go only into the control plane node configuration.
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
      # Pods in the talos-backup namespace can take etcd snapshots through the Talos API, and nothing else
      yamlencode({
        apiVersion                  = "v1alpha1"
        kind                        = "KubeTalosAPIAccessConfig"
        allowedRoles                = ["os:etcd:backup"]
        allowedKubernetesNamespaces = ["talos-backup"]
      }),
    ] : []
  )
}

# Equivalent of `talosctl apply-config --insecure`
resource "talos_machine_configuration_apply" "node" {
  for_each   = var.nodes
  depends_on = [proxmox_virtual_environment_vm.node]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip
}

# Equivalent of `talosctl bootstrap`
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.node]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip
}

# Equivalent of `talosctl kubeconfig`
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
