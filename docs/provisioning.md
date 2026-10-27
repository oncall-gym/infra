# Provisioning

The Proxmox VMs and the Talos cluster are described in the Terraform configuration in `terraform/cluster/`. The S3 buckets are a separate configuration in `terraform/cloud/`.

## Nodes

The node addresses are fixed on the router (DHCP reservations by MAC address, which Terraform sets explicitly).

| Node | Role | IP address | VMID | vCPU | RAM | Disk |
| --- | --- | --- | --- | --- | --- | --- |
| `talos-cp1` | control plane | 192.168.91.201 | 201 | 2 | 4 GB | 20 GB |
| `talos-w1` | worker | 192.168.91.211 | 211 | 4 | 5 GB | 20 GB |
| `talos-w2` | worker | 192.168.91.212 | 212 | 4 | 5 GB | 20 GB |

The budget for all VMs is 12 vCPU and 16 GB of RAM; the remaining 2 vCPU and 2 GB are left for Proxmox itself. The range 192.168.91.220–192.168.91.230 belongs to MetalLB (see [networking.md](networking.md)).

Kubernetes API: `https://192.168.91.201:6443`; Talos API endpoint: 192.168.91.201. The node parameters live in `terraform/cluster/terraform.tfvars`, which is not in Git.

## Cluster configuration (`terraform/cluster/`)

A single `terraform apply` creates the VMs, generates the Talos secrets and machine configs, applies them, bootstraps etcd and exports the kubeconfig and talosconfig. The nodes stay `NotReady` until a CNI is installed, which is why the cluster is brought up with [bootstrap.sh](bootstrap.md).

Notes on `main.tf`:

- The VMs boot with UEFI; the Talos ISO is attached for the first boot, and installation to disk is described by the `UnattendedInstallConfig` document. The installer image comes from `factory.talos.dev`.
- The QEMU guest agent device is enabled. The Talos image includes the `qemu-guest-agent` extension, and without the device a node never leaves the `Booting` stage.
- The control plane config removes `KubeFlannelCNIConfig` and disables kube-proxy: Cilium replaces both.
- The same config adds `KubeTalosAPIAccessConfig`, which lets pods in the `talos-backup` namespace use the Talos API with the `os:etcd:backup` role only (see [backup.md](backup.md)).
- The Talos secrets and machine configs exist only in the Terraform state. There are no `controlplane.yaml` or `worker.yaml` files.

Run the commands from that directory; `bootstrap.sh` calls them with `-chdir` and writes the kubeconfig and talosconfig to the repository root.

```sh
cd terraform/cluster
terraform init
terraform plan
terraform apply
terraform output -raw kubeconfig  > ../../kubeconfig
terraform output -raw talosconfig > ../../talosconfig
```

## Terraform state

The state is in the bucket `lab-tfstate-2a7416` in cloud.ru Object Storage, key `talos/terraform.tfstate` (`backend.tf`). The bucket is versioned, and `use_lockfile` prevents concurrent runs. The state contains the cluster secrets.

## S3 buckets (`terraform/cloud/`)

`terraform/cloud/` is a separate Terraform configuration with its own state in the same bucket (key `cloud/terraform.tfstate`). Run its commands from that directory.

| Bucket | Purpose | Settings |
| --- | --- | --- |
| `lab-tfstate-2a7416` | Terraform state of both configurations | versioning |
| `lab-etcd-backup-2a7416` | etcd snapshots | versioning; Object Lock for 14 days in `GOVERNANCE` mode; objects deleted after 30 days, noncurrent versions after 7 days |

cloud.ru specifics:

- There is no STS, IAM or EC2 metadata, so the provider and both `backend.tf` files skip those checks (`skip_*` flags) and use path-style addressing.
- The lifecycle rule is applied by an AWS CLI command from `terraform_data.etcd_lifecycle`: the `aws_s3_bucket_lifecycle_configuration` resource waits for response fields cloud.ru does not return. `terraform apply` in `terraform/cloud/` therefore needs the `aws` utility.
- Object Lock can only be enabled when a bucket is created. `GOVERNANCE` lets an administrator lift the lock in an emergency; `COMPLIANCE` would not.
- The bucket names are literal strings in both `backend.tf` files, because a backend cannot read outputs. The suffix comes from `random_id`: if the buckets are re-created, fix the names in both files.
- The access keys belong to cloud.ru service accounts created in the console, not in Terraform: one for Terraform and a separate upload-only one for the backup job.

## Local environment

[direnv](https://direnv.net/) loads `.envrc` when you enter the repository (run `direnv allow` after cloning). `.envrc` is in Git and holds only paths and non-secret settings:

| Variable | Purpose |
| --- | --- |
| `KUBECONFIG` | the lab kubeconfig, kept outside the repository |
| `TALOSCONFIG` | `./talosconfig` |
| `SOPS_AGE_KEY_FILE` | the age key for [secrets](secrets.md) |
| `AWS_PROFILE` | the AWS CLI profile with access to cloud.ru S3 |
| `TF_INPUT=0` | Terraform fails right away instead of prompting for a missing variable |

Secrets are not in `.envrc`. It sources `.envrc.local` (git-ignored), which reads the Proxmox API token from the OS keyring and exports `TF_VAR_proxmox_api_token`; the token itself is kept in a password manager. Without direnv, export that variable by hand.

`bootstrap.sh` writes the kubeconfig to `./kubeconfig`. After the cluster is re-created, copy it to the path in `KUBECONFIG` again (`install -m 600 kubeconfig <path>`). The command examples in these docs pass `--kubeconfig ./kubeconfig` explicitly, so they work without direnv.
