# local-infra

Local infrastructure for the MVP of a DevOps troubleshooting trainer.

## Purpose

This repository describes the environment where the trainer MVP is deployed and tested: a platform that will host training labs with pre-planted faults for practising diagnosis and repair.

## Decisions made

| Area | Decision |
| --- | --- |
| Virtualization | Proxmox VE 9.2.21 |
| Node OS | Talos Linux v1.14.2 |
| Kubernetes | v1.37.0 |
| Cluster name | `lab` |
| Cluster layout | 1 control plane (master) and 2 worker nodes |
| Node IP addresses | Statically assigned on the router (see "Node network") |
| Provisioning | Terraform: providers `bpg/proxmox` (VMs) and `siderolabs/talos` (Talos configuration and bootstrap) |
| Terraform state | Remote: bucket `lab-tfstate-2a7416` in cloud.ru Object Storage (S3) with versioning and locking via `use_lockfile` |
| Cloud resources | cloud.ru Object Storage: buckets for Terraform state and for etcd snapshots, described in Terraform in the `cloud/` directory |
| Local environment | direnv: `.envrc` (in Git, no secrets) sets the config paths and the AWS profile; the Proxmox token comes from the system keyring |
| Deployment from scratch | The `bootstrap.sh` script: Terraform, then the Gateway API CRDs and Cilium, then Argo CD; the lab root certificate is restored from a local copy, and the age key for decrypting secrets is put into the cluster |
| Cluster network (CNI) | Cilium v1.20.2 instead of the built-in Flannel and kube-proxy, with Hubble (relay and UI) |
| Application delivery | Argo CD v3.5.3 (GitOps, app of apps pattern), manifests in the `gitops/` directory |
| Argo CD login | Through GitHub (OAuth, built-in Dex); the local `admin` account is disabled |
| Load balancing (`LoadBalancer` services) | MetalLB v0.16.1, L2 mode, address pool 192.168.91.220–192.168.91.230 |
| Inbound traffic (ingress) | Gateway API v1.6.1 implemented by Cilium: one shared gateway `lab` on 192.168.91.220, HTTPS (HTTP redirects to HTTPS), names `*.lab.home.arpa` |
| TLS and certificates | cert-manager v1.21.2 with the lab's own certificate authority (`ClusterIssuer` `lab-ca`); TLS terminates at the gateway, the certificate is `*.lab.home.arpa` |
| Secrets in Git | SOPS with an age key: encrypted `SopsSecret` objects in `gitops/secrets`, decrypted in the cluster by sops-secrets-operator 0.21.2 |
| Observability (metrics and alerts) | Chart `victoria-metrics-k8s-stack` 0.95.2: VictoriaMetrics v1.153.0 instead of Prometheus, Alertmanager (email notifications), Grafana 13.2.3 at https://grafana.lab.home.arpa |
| etcd backup | `talos-backup` (a `CronJob` in the cluster): an etcd snapshot every 3 hours, zstd compression and age encryption, upload to the bucket `lab-etcd-backup-2a7416` in cloud.ru Object Storage; restore follows the runbook `docs/runbooks/etcd-restore.md` |

## Node network

The IP addresses of the Talos hosts are statically assigned on the router:

| Node | Role | IP address | Node name in the cluster | Terraform key | VMID |
| --- | --- | --- | --- | --- | --- |
| master | control plane | 192.168.91.201 | `talos-cp1` | `cp1` | 201 |
| worker 1 | worker | 192.168.91.211 | `talos-w1` | `w1` | 211 |
| worker 2 | worker | 192.168.91.212 | `talos-w2` | `w2` | 212 |

The VM MAC addresses are set explicitly in Terraform so that they match the leases on the router.

The range 192.168.91.220–192.168.91.230 in the same subnet is given to MetalLB for `LoadBalancer` service addresses (see "Load balancing (MetalLB)"). The first address of the range, 192.168.91.220, is reserved for the gateway `lab` (see "Inbound traffic (Gateway API)").

## Cluster

The Talos cluster `lab` is deployed by the `bootstrap.sh` script (see "Deployment from scratch"); the VMs and the Talos configuration are described in Terraform (see "Provisioning"). All three nodes are `Ready`.

| Parameter | Value |
| --- | --- |
| Talos API (endpoint) | 192.168.91.201 |
| Kubernetes API | https://192.168.91.201:6443 |
| `talosctl` context | `lab` |
| `kubectl` context | `admin@lab` |

Status check:

```sh
kubectl --kubeconfig ./kubeconfig get nodes -o wide
talosctl --talosconfig ./talosconfig -n 192.168.91.201 version
```

## Provisioning

The Proxmox VMs and the Talos cluster are described in the Terraform configuration in the repository root. A single `terraform apply` creates the VMs, applies the machine config, runs the bootstrap and fetches the kubeconfig. After that the nodes stay `NotReady` until a CNI is installed, so the cluster is brought up from scratch by the `bootstrap.sh` script (see "Deployment from scratch").

| Component | Version |
| --- | --- |
| Terraform | v1.16.5 (>= 1.6 required) |
| Provider `bpg/proxmox` | 0.115.0 |
| Provider `siderolabs/talos` | 0.12.0 |

Files:

| File | Purpose | In VCS |
| --- | --- | --- |
| `main.tf` | providers, VMs, Talos secrets and configuration, bootstrap | yes |
| `variables.tf` | variables (Proxmox address, datastore, ISO, Talos version, node definitions) | yes |
| `outputs.tf` | outputs `kubeconfig` and `talosconfig` (sensitive) | yes |
| `backend.tf` | state storage in cloud.ru S3: bucket `lab-tfstate-2a7416`, key `talos/terraform.tfstate` | yes |
| `.terraform.lock.hcl` | pinned provider versions | yes |
| `terraform.tfvars` | installer image and node parameters (VMID, IP, MAC, CPU, RAM) | no |
| `terraform.tfstate`, `terraform.tfstate.backup` | leftovers of the local state after the move to S3: the first file is empty, the second holds the last local copy of the state with the cluster secrets | no |
| `kubeconfig`, `talosconfig` | client configs exported from the Terraform outputs | no |
| `bootstrap.sh` | cluster deployment from scratch (see "Deployment from scratch") | yes |
| `.sops.yaml` | `sops` encryption rules for `*.enc.yaml` files (see "Secrets (SOPS)") | yes |
| `.envrc` | direnv environment: config paths and the AWS profile, no secrets (see "Local environment (direnv)") | yes |
| `.envrc.local` | personal and secret direnv settings: the Proxmox token from the keyring | no |
| `cloud/` | a separate Terraform configuration for the cloud.ru buckets (see "Cloud storage (cloud.ru)") | yes |
| `docs/runbooks/etcd-restore.md` | runbook for restoring etcd from a snapshot (see "etcd backup") | yes |
| `.restore/` | working directory for etcd restores: downloaded and decrypted snapshots | no |

Configuration notes:

- The VMs boot with UEFI (OVMF); the disk is `scsi0` on `local-lvm` (20 GB), and the Talos ISO (`local:iso/talos.iso`) is attached as `ide3`.
- Installation to disk is described by the `UnattendedInstallConfig` document (Talos 1.14); the installer image comes from `factory.talos.dev` and is set by the `talos_installer_image` variable.
- Node names are set by the `HostnameConfig` document: `talos-<node key>`.
- The VMs have the QEMU guest agent device enabled (wait timeout: 2 minutes). The Talos image includes the `qemu-guest-agent` extension: without the agent device its service does not start, and the node stays in the `Booting` stage forever.
- The built-in Flannel and kube-proxy are disabled in favour of Cilium: the control plane machine config removes the `KubeFlannelCNIConfig` document and adds `KubeProxyConfig` with `enabled: false`. These are cluster-level settings, so they do not go into the worker configuration.
- The same control plane machine config enables access to the Talos API from inside the cluster with the `KubeTalosAPIAccessConfig` document: only for pods in the `talos-backup` namespace and only with the `os:etcd:backup` role. `talos-backup` uses it to take etcd snapshots (see "etcd backup").
- The cluster secrets (`talos_machine_secrets`) and the generated machine configs are stored only in the state; there are no separate `controlplane.yaml` and `worker.yaml` files any more.
- The state is remote: it lives in the bucket `lab-tfstate-2a7416` in cloud.ru Object Storage under the key `talos/terraform.tfstate` (`backend.tf`). The bucket has versioning enabled, so a broken state can be rolled back. `use_lockfile` locking protects against concurrent runs: a `.tflock` file is created next to the state for the duration of an operation.
- Access to the state requires the AWS CLI profile `cloudru` (see "Cloud storage (cloud.ru)"): without it `terraform init`, `plan` and `apply` do not work.

Usage (direnv sets the environment variables, see "Local environment (direnv)"):

```sh
terraform init
terraform plan
terraform apply

terraform output -raw kubeconfig > kubeconfig
terraform output -raw talosconfig > talosconfig
```

The Proxmox API token is passed only through the `TF_VAR_proxmox_api_token` environment variable and is never written to files in the repository. Without direnv it has to be set by hand: `export TF_VAR_proxmox_api_token='terraform@pve!tf=<uuid>'`.

## Local environment (direnv)

[direnv](https://direnv.net/) sets the environment variables for working with the lab when you enter the repository directory. After cloning, and after every change to `.envrc`, it has to be allowed with `direnv allow`.

The `.envrc` file is in Git: it contains no secrets, only paths to them.

| Variable | Value | Why |
| --- | --- | --- |
| `KUBECONFIG` | `~/.kube/home/lab` | `kubectl` and `helm` work with the `lab` cluster without the `--kubeconfig` flag |
| `TALOSCONFIG` | `./talosconfig` | `talosctl` works without the `--talosconfig` flag |
| `SOPS_AGE_KEY_FILE` | `~/.lab/age.key` | `sops` finds the age key (see "Secrets (SOPS)") |
| `AWS_PROFILE` | `cloudru` | AWS CLI and Terraform talk to cloud.ru S3 |
| `TF_INPUT` | `0` | Terraform does not ask questions interactively: without the Proxmox token it fails immediately |

`KUBECONFIG` points outside the repository: `~/.kube/home/lab` is a copy of the `kubeconfig` file, readable only by the owner. `bootstrap.sh` and the commands in "Provisioning" still export the kubeconfig to `./kubeconfig` in the repository root, so after the cluster is re-created the file has to be copied again:

```sh
install -m 600 kubeconfig ~/.kube/home/lab
```

The examples in this README pass `--kubeconfig ./kubeconfig` explicitly, so they work without direnv too.

Personal and secret settings live in `.envrc.local`, which `.envrc` loads if it exists. It never reaches Git (it is listed in `.gitignore`).

The Proxmox API token:

- It is stored in Bitwarden, in the entry `terraform@pve!tf`.
- The `lab-secrets-sync` script (`~/.local/bin`, outside the repository) copies it from Bitwarden into the system keyring. It needs the `bw` and `secret-tool` utilities. The script is run on a new machine and after a token rotation.
- `.envrc.local` reads the token from the keyring (`secret-tool lookup service lab key proxmox-api-token`) and sets `TF_VAR_proxmox_api_token`. The token is never stored on disk in plain text.
- If the token is missing from the keyring, direnv prints an error with a hint: `lab-secrets-sync && direnv reload`.

## Cloud storage (cloud.ru)

Outside Proxmox the lab has two buckets in cloud.ru Object Storage (S3-compatible storage). They are described by a separate Terraform configuration in the `cloud/` directory with its own state.

| Parameter | Value |
| --- | --- |
| Service | cloud.ru Object Storage, endpoint `https://s3.cloud.ru`, region `ru-central-1` |
| Provider `hashicorp/aws` | 6.68.0 (pointed at cloud.ru S3) |
| Provider `hashicorp/random` | 3.9.1 (the suffix in the bucket names) |
| Access | AWS CLI profile `cloudru`: settings in `~/.aws/config`, access keys in `~/.aws/credentials` |
| State | the same bucket `lab-tfstate-2a7416`, key `cloud/terraform.tfstate` (`cloud/backend.tf`) |

Buckets:

| Bucket | Purpose | Settings |
| --- | --- | --- |
| `lab-tfstate-2a7416` | Terraform state: `talos/terraform.tfstate` (the cluster) and `cloud/terraform.tfstate` (the buckets themselves) | versioning |
| `lab-etcd-backup-2a7416` | etcd snapshots (prefix `etcd/`, see "etcd backup") | versioning; Object Lock: 14 days in `GOVERNANCE` mode; lifecycle rule `expire-old`: objects are deleted after 30 days, noncurrent versions after 7 days |

Files:

| File | Purpose |
| --- | --- |
| `cloud/main.tf` | providers, both buckets and their settings, outputs `tfstate_bucket` and `etcd_backup_bucket` |
| `cloud/backend.tf` | storage of this configuration's state in S3 |
| `cloud/.terraform.lock.hcl` | pinned provider versions |

Notes:

- cloud.ru has no AWS STS, IAM or EC2 metadata services, so calls to them are disabled in the provider and in both `backend.tf` files (`skip_credentials_validation`, `skip_region_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`), plus `skip_s3_checksum` in the backend. Addressing is path-style (`use_path_style`).
- Object Lock can only be enabled when a bucket is created. For 14 days each etcd snapshot can be neither deleted nor overwritten. `GOVERNANCE` mode lets an administrator (`s3e.admin`) lift the lock as a last resort; in `COMPLIANCE` mode nobody could.
- The lifecycle rule is written not by the `aws_s3_bucket_lifecycle_configuration` resource but by an AWS CLI command from the `terraform_data` `etcd_lifecycle`: the provider resource waits for response fields that cloud.ru S3 does not return. When the rule JSON changes, the command runs again. That is why `terraform apply` in `cloud/` needs the `aws` utility.
- The state bucket is created by this same configuration, so `cloud/backend.tf` was added after the buckets existed: the state was local at first and was then moved into the bucket.
- The bucket names are written in `backend.tf` and `cloud/backend.tf` as literal strings: a backend cannot read Terraform outputs. If a bucket is re-created, the suffix changes and the name has to be fixed in both files.
- The etcd snapshot bucket is written to by `talos-backup` from the cluster (see "etcd backup"). It has its own access keys, those of the cloud.ru service account `sa-etcd-backup`. The `cloudru` profile uses the keys of the service account `sa-lab-admin`. Both service accounts and their keys were created in the cloud.ru console: they are not in Terraform.

Usage:

```sh
cd cloud
terraform init
terraform plan
terraform apply
terraform output
```

## Deployment from scratch

The `bootstrap.sh` script brings up the whole cluster with one command. Everything outside its steps is installed by Argo CD from Git.

Script steps:

1. Environment check before any changes: the age key file, the `terraform`, `kubectl`, `helm` and `jq` utilities, and the deploy key file. If anything is missing, the script exits with an error right away.
2. `terraform apply -parallelism=1`: the VMs and the Talos cluster. Terraform asks for confirmation as usual.
3. Export of `kubeconfig` and `talosconfig` from the Terraform outputs into the repository root.
4. Wait for the API server to become ready.
5. Installation of the Gateway API v1.6.1 resource types (CRDs): `kubectl apply --server-side` of `standard-install.yaml` from the `kubernetes-sigs/gateway-api` release. They are needed before Cilium: the operator creates the `GatewayClass` `cilium` only if the CRDs already exist when it starts. The step is skipped if the CRD `gateways.gateway.networking.k8s.io` is already in the cluster.
6. Installation of Cilium with Helm into `kube-system`, with values from `gitops/cilium/values.yaml`. Without a CNI the nodes stay `NotReady`, so Cilium is installed before the other components. The step is skipped if the cluster already has the Argo CD application `cilium`.
7. Wait for the three nodes to register and become `Ready`.
8. Installation of Argo CD with Helm into `argocd`, with values from `gitops/argocd/values.yaml`. The step is skipped if the cluster already has the Argo CD application `argocd`.
9. Creation of the secret `repo-local-infra` with the SSH key for repository access.
10. Creation of the `cert-manager` namespace and restore of the secret `lab-root-ca` (the lab root certificate with its private key) from the local copy, before cert-manager appears in the cluster; otherwise it would issue a new root certificate. If there is no copy, the step is skipped; if the secret is already in the cluster, it is not overwritten.
11. Creation of the `sops-secrets-operator` namespace and the secret `sops-age-key-file` with the age private key, which the operator uses to decrypt secrets from Git (see "Secrets (SOPS)").
12. Application of the root application `gitops/root.yaml`.
13. Only if there was no local copy: wait until cert-manager creates the secret `lab-root-ca` (up to 15 minutes) and save it to the local copy for future re-creations. If the secret does not appear in that time, the script exits with an error: the cluster is up, and the copy has to be saved by hand.

What is needed before the run:

- `terraform`, `kubectl`, `helm` and `jq` installed, and `terraform init` done;
- a filled-in `terraform.tfvars` and the `TF_VAR_proxmox_api_token` environment variable (direnv sets it, see "Local environment (direnv)");
- the AWS CLI profile `cloudru` with access to the bucket `lab-tfstate-2a7416`, which holds the Terraform state (see "Cloud storage (cloud.ru)");
- the Talos ISO in the Proxmox storage (`local:iso/talos.iso`);
- access to `github.com` from the machine that runs the script (the Gateway API CRD manifest is downloaded from there);
- the private SSH key that gives Argo CD access to the repository. The path is set by the `DEPLOY_KEY` environment variable, `~/argocd-deploy-key` by default;
- optionally, a local copy of the secret `lab-root-ca`, to keep the previous root certificate. The path is set by the `CA_SECRET` environment variable, `~/.lab/lab-root-ca-secret.json` by default. On the first run without a copy the script creates it;
- the age private key that the secrets in `gitops/secrets` are encrypted with. The path is set by the `AGE_KEY` environment variable, `~/.lab/age.key` by default. Without it the script does not start: the key cannot be generated again, or the secrets from Git would not decrypt.

Run (in the repository directory with direnv allowed; without it, set `TF_VAR_proxmox_api_token` by hand first):

```sh
./bootstrap.sh
```

Notes:

- The script can be run again, including on a running cluster. It does not touch what Argo CD already manages: the Gateway API CRDs are installed only if they are missing, and the Helm releases `cilium` and `argocd` only if there are no Argo CD applications with the same names. The secret `repo-local-infra`, the namespaces `cert-manager` and `sops-secrets-operator`, the secret `sops-age-key-file` and the root application are applied with `kubectl apply`.
- The chart versions are set in two places and must match: `CILIUM_VERSION` with `targetRevision` in `gitops/apps/cilium.yaml`, and `ARGOCD_VERSION` with `targetRevision` in `gitops/apps/argocd.yaml`. Otherwise Argo CD brings the release to the version from Git right after the installation.
- The Gateway API version is also set twice: in the `GATEWAY_API_VERSION` variable in `bootstrap.sh` and in `targetRevision` of the application `gitops/apps/gateway-api-crds.yaml`. Both must match each other and the version Cilium is built against.
- After step 12 Argo CD takes over the releases `cilium` and `argocd` installed by the script, and the Gateway API resource types (application `gateway-api-crds`).
- The script does not install cert-manager or the lab certificate authority: Argo CD deploys them. The script only carries the secret `lab-root-ca` across cluster re-creations: with the restored secret the root certificate stays the same, and trust on client machines does not have to be set up again (see "Certificates (cert-manager)").
- The local copy of the secret is saved as JSON without the service fields (`uid`, `resourceVersion`, `creationTimestamp`, `managedFields`, `ownerReferences`), readable only by the owner. It holds the private key of the certificate authority: the script advises copying the file into a password manager.
- The script does not install sops-secrets-operator: Argo CD deploys it. The script only puts the age key into the cluster before the root application is applied, so that the operator can decrypt secrets right away.
- Argo CD is installed with the `admin` account already disabled and with GitHub login. Logging in to the UI works only after Argo CD has deployed sops-secrets-operator and the application `platform-secrets`, and the operator has created the secret `argocd-github-oauth` (see "Argo CD login").

## Cluster network (Cilium)

The cluster CNI is Cilium. It replaces Flannel and kube-proxy built into Talos (both are disabled in the machine config, see "Provisioning"). `bootstrap.sh` does the first installation; after that the release is managed by the Argo CD application `cilium`.

| Parameter | Value |
| --- | --- |
| Cilium | v1.20.2 |
| Helm chart | `cilium` 1.20.2 from `https://helm.cilium.io` |
| Namespace | `kube-system` |
| Release name | `cilium` |
| IPAM | `kubernetes` (pod subnet 10.244.0.0/16, the Talos default) |
| kube-proxy replacement | enabled (`kubeProxyReplacement: true`) |
| Hubble | relay and UI enabled |
| Gateway API | enabled (`gatewayAPI.enabled: true`), `GatewayClass` `cilium` |

Notes (values in `gitops/cilium/values.yaml`, following the Talos 1.14 documentation):

- Cilium reaches the API server through KubePrism, the local Talos load balancer on `localhost:7445`.
- The agent's set of capabilities is listed explicitly, cgroup automount is disabled, and the host's `/sys/fs/cgroup` is used.
- To save memory, the Cilium operator runs as a single replica.
- Addresses for `LoadBalancer` services are still handed out by MetalLB.
- Cilium implements Gateway API: it accepts inbound HTTP and HTTPS traffic through the gateway `lab` (see "Inbound traffic (Gateway API)"). For that, the Gateway API CRDs must be installed before the Cilium operator starts.

Hubble UI is available from the local network at https://hubble.lab.home.arpa (the service `hubble-ui` stays `ClusterIP`; the gateway publishes it).

Status check and fallback access to Hubble UI bypassing the gateway:

```sh
kubectl --kubeconfig ./kubeconfig -n kube-system get pods -l app.kubernetes.io/part-of=cilium
kubectl --kubeconfig ./kubeconfig -n kube-system port-forward svc/hubble-ui 12000:80
```

## Application delivery (GitOps)

Argo CD is installed in the cluster and keeps the cluster state in sync with the `gitops/` directory of this repository (branch `main`).

| Parameter | Value |
| --- | --- |
| Argo CD | v3.5.3 |
| Helm chart | `argo-cd` 10.9.6 from `https://argoproj.github.io/argo-helm` |
| Namespace | `argocd` |
| Release name | `argocd` |
| Repository | `git@github.com:artem-dev-ops/DevOps-Troubleshoot-Training.git` (SSH) |
| Argo CD project | `default` |

Layout:

| Path | Purpose |
| --- | --- |
| `gitops/root.yaml` | root application `root`: watches the `gitops/apps` directory |
| `gitops/apps/` | `Application` manifests, one per component |
| `gitops/apps/argocd.yaml` | application `argocd`: Argo CD manages its own Helm release |
| `gitops/argocd/values.yaml` | Argo CD chart values |
| `gitops/apps/cilium.yaml` | application `cilium`: the Cilium Helm chart |
| `gitops/cilium/values.yaml` | Cilium chart values (also used by `bootstrap.sh`) |
| `gitops/apps/metallb.yaml` | application `metallb`: the MetalLB Helm chart |
| `gitops/apps/metallb-config.yaml` | application `metallb-config`: watches the `gitops/metallb-config` directory |
| `gitops/metallb-config/pool.yaml` | MetalLB address pool and L2 advertisement |
| `gitops/apps/gateway-api-crds.yaml` | application `gateway-api-crds`: the Gateway API resource types (CRDs) from `kubernetes-sigs/gateway-api` |
| `gitops/apps/gateway.yaml` | application `gateway`: watches the `gitops/gateway` directory |
| `gitops/gateway/gateway.yaml` | the gateway `lab` |
| `gitops/gateway/routes.yaml` | `HTTPRoute` routes to Argo CD and Hubble UI, and the HTTP-to-HTTPS redirect |
| `gitops/gateway/grafana-route.yaml` | `HTTPRoute` route to Grafana |
| `gitops/apps/cert-manager.yaml` | application `cert-manager`: the cert-manager Helm chart (values in the manifest itself) |
| `gitops/apps/cert-manager-config.yaml` | application `cert-manager-config`: watches the `gitops/cert-manager` directory |
| `gitops/cert-manager/issuers.yaml` | the lab certificate authority: the `ClusterIssuer` issuers and the root certificate |
| `gitops/apps/sops-secrets-operator.yaml` | application `sops-secrets-operator`: the operator's Helm chart (values in the manifest itself) |
| `gitops/apps/platform-secrets.yaml` | application `platform-secrets`: watches the `gitops/secrets` directory |
| `gitops/secrets/argocd-github-oauth.enc.yaml` | encrypted `SopsSecret`: the GitHub OAuth app credentials for Argo CD login |
| `gitops/secrets/alertmanager-config.enc.yaml` | encrypted `SopsSecret`: the Alertmanager configuration |
| `gitops/secrets/talos-backup-s3.enc.yaml` | encrypted `SopsSecret`: access keys for the etcd snapshot bucket |
| `gitops/apps/monitoring.yaml` | application `monitoring`: the `victoria-metrics-k8s-stack` Helm chart (values in the manifest itself) |
| `gitops/apps/talos-backup.yaml` | application `talos-backup`: watches the `gitops/talos-backup` directory |
| `gitops/talos-backup/cronjob.yaml` | `CronJob` `talos-backup`: scheduled etcd snapshots |
| `gitops/talos-backup/talos-serviceaccount.yaml` | Talos `ServiceAccount` (`talos.dev/v1alpha1`): access to the Talos API with the `os:etcd:backup` role |
| `gitops/talos-backup/alerts.yaml` | `VMRule` `talos-backup`: alerts for a stale or missing snapshot |

How it works:

- The application `root` applies everything in `gitops/apps`. To add a component to the cluster, put an `Application` manifest there and push a commit to `main`.
- All applications have automated sync with `prune` and `selfHeal`: manual changes in the cluster are reverted, and whatever is deleted from Git is deleted from the cluster. The exception is `gateway-api-crds`: its `prune` is disabled so that resource types are never deleted automatically.
- To save memory, the notifications controller is disabled in the chart. Dex is enabled: GitHub login works through it (see "Argo CD login").
- `argocd-server` runs without TLS (`configs.params.server.insecure: true`): TLS terminates at the gateway, and the gateway talks to the service over HTTP.
- Repository access uses the SSH key from the secret `repo-local-infra` in the `argocd` namespace. `bootstrap.sh` creates the secret; it is not stored in Git.

The initial installation of Argo CD, the creation of the secret `repo-local-infra` and the application of `gitops/root.yaml` are done by `bootstrap.sh` (see "Deployment from scratch"). After that Argo CD maintains itself.

The Argo CD UI is available from the local network at https://argocd.lab.home.arpa (the service `argocd-server` stays `ClusterIP`; the gateway publishes it, see "Inbound traffic (Gateway API)").

Status check and fallback access to the UI bypassing the gateway (over HTTP: `argocd-server` runs without TLS). GitHub login does not work with this kind of access: after login GitHub redirects to the main address.

```sh
kubectl --kubeconfig ./kubeconfig -n argocd get applications
kubectl --kubeconfig ./kubeconfig -n argocd port-forward svc/argocd-server 8080:80
```

### Argo CD login

Users log in to the Argo CD UI through GitHub: the built-in Dex acts as a GitHub OAuth client. The local `admin` account is disabled. The settings are in `gitops/argocd/values.yaml`.

| Parameter | Value |
| --- | --- |
| Argo CD address | `https://argocd.lab.home.arpa` (`global.domain` and `configs.cm.url`) |
| Dex connector | `github` (`configs.cm."dex.config"`) |
| GitHub OAuth app credentials | secret `argocd-github-oauth` in the `argocd` namespace, keys `clientID` and `clientSecret` |
| Callback URL in the GitHub OAuth app | `https://argocd.lab.home.arpa/api/dex/callback` |
| Local `admin` | disabled (`configs.cm."admin.enabled": "false"`) |
| Who can log in | only members of the GitHub organization `oncall-gym` (`orgs` in the connector config) |
| Permissions | `configs.rbac`: no default role (`policy.default: ""`), `role:admin` is granted to the GitHub team `oncall-gym:admins` in `policy.csv` |

Notes:

- The secret `argocd-github-oauth` is stored in Git encrypted (`gitops/secrets/argocd-github-oauth.enc.yaml`); in the cluster it is created by sops-secrets-operator (see "Secrets (SOPS)"). In `dex.config` the values are substituted through references of the form `$argocd-github-oauth:clientID`; for that the secret carries the label `app.kubernetes.io/part-of: argocd`.
- Permissions follow GitHub team membership, not personal accounts. Dex passes the user's teams in the `groups` claim as `<org>:<team>` (`scopes: "[groups, email]"`), and `policy.csv` maps the team `oncall-gym:admins` to `role:admin`. To grant or revoke admin access, add the user to that team or remove them from it in GitHub: nothing changes in Git.
- A GitHub user outside the organization `oncall-gym` cannot log in at all. A member of the organization who is not in the `admins` team can log in but sees nothing: there is no default role. To give another team access, add a line `g, oncall-gym:<team>, <role>` to `configs.rbac."policy.csv"`.
- If the organization restricts third-party OAuth apps, the Argo CD OAuth app has to be approved for it; otherwise Dex cannot read the team membership and the login fails.
- Logging in from a client machine requires access to `github.com`, and Dex in the cluster must be able to reach the GitHub API.
- There is no fallback password login. If GitHub login breaks, check the application state with `kubectl`, and bring `admin` back by editing `gitops/argocd/values.yaml`.

## Inbound traffic (Gateway API)

Outside traffic is accepted by one shared gateway `lab`, implemented by Cilium (Gateway API). Services are available over HTTPS; HTTP requests are redirected to HTTPS. There is no separate ingress controller in the cluster.

| Parameter | Value |
| --- | --- |
| Gateway API (CRDs) | v1.6.1, `standard` channel (the version Cilium 1.20 is built against) |
| Implementation | Cilium, `GatewayClass` `cilium` (controller `io.cilium/gateway-controller`) |
| Gateway | `Gateway` `lab` in the `gateway` namespace |
| Address | 192.168.91.220: the `LoadBalancer` service `cilium-gateway-lab` (ports 80 and 443); the address is handed out by MetalLB |
| Listener `http` | HTTP, port 80, names `*.lab.home.arpa`, routes only from the `gateway` namespace; the only thing here is the redirect to HTTPS |
| Listener `https` | HTTPS, port 443, names `*.lab.home.arpa`, routes allowed from any namespace |
| TLS | terminates at the gateway (`mode: Terminate`); the certificate is the secret `lab-wildcard-tls` in the `gateway` namespace, issued by cert-manager (see "Certificates (cert-manager)") |

Published services:

| Address | `HTTPRoute` | Service |
| --- | --- | --- |
| https://argocd.lab.home.arpa | `argocd` in the `argocd` namespace | `argocd-server:80` |
| https://hubble.lab.home.arpa | `hubble` in the `kube-system` namespace | `hubble-ui:80` |
| https://grafana.lab.home.arpa | `grafana` in the `monitoring` namespace | `vmks-grafana:80` |

How it is built:

- The Gateway API resource types are installed by the application `gateway-api-crds` from the `kubernetes-sigs/gateway-api` repository (tag `v1.6.1`, directory `config/crd`). It has `prune` disabled and `ServerSideApply=true` enabled: the definitions are too large for a regular `apply`.
- When deploying from scratch, `bootstrap.sh` installs the same types before Cilium: the Cilium operator creates the `GatewayClass` `cilium` only if the CRDs already exist when it starts.
- The Cilium chart values enable `gatewayAPI.enabled` (and also `enableAlpn` and `enableAppProtocol`).
- The application `gateway` applies the `gitops/gateway` directory: `gateway.yaml` (the gateway), `routes.yaml` (the redirect and the routes to Argo CD and Hubble UI) and `grafana-route.yaml` (the route to Grafana). Argo CD creates the `gateway` namespace (`CreateNamespace=true`); `SkipDryRunOnMissingResource=true` and sync retries are enabled for the case when the CRDs are not installed yet.
- The gateway address is pinned by the annotation `metallb.io/loadBalancerIPs: 192.168.91.220` (`spec.infrastructure.annotations` in the `Gateway`): Cilium copies it to the service it creates.
- The gateway certificate is requested by the annotation `cert-manager.io/cluster-issuer: lab-ca` on the `Gateway` itself: from the `https` listener cert-manager creates the `Certificate` `lab-wildcard-tls` for `*.lab.home.arpa` and renews it. There is no separate `Certificate` manifest in Git.
- The `HTTPRoute` `http-to-https` in the `gateway` namespace is attached to the `http` listener and answers every request with a 301 redirect to HTTPS. There are no other routes on port 80: the listener accepts routes only from its own namespace.
- The service routes are attached to the `https` listener (`sectionName: https` in `parentRefs`). They live in the `gitops/gateway` directory (`routes.yaml`, and `grafana-route.yaml` for Grafana) but are created in the namespaces of their services (`argocd`, `kube-system`, `monitoring`), so no `ReferenceGrant` is needed.
- TLS terminates at the gateway, and the gateway talks to the services over HTTP, so `argocd-server` runs with `server.insecure: true` (`gitops/argocd/values.yaml`).
- The names `*.lab.home.arpa` work only in the local network and must resolve to 192.168.91.220. The DNS records are configured outside the repository.

To publish one more service, add an `HTTPRoute` to `gitops/gateway/routes.yaml` (in the service's namespace, with `parentRefs` pointing at the gateway `lab` in the `gateway` namespace and `sectionName: https`) and a DNS record for the new name. A new certificate is not needed: a name of the form `<service>.lab.home.arpa` is covered by the shared gateway certificate.

Status check:

```sh
kubectl --kubeconfig ./kubeconfig get gatewayclass
kubectl --kubeconfig ./kubeconfig get gateway,httproute -A
curl -I --resolve argocd.lab.home.arpa:80:192.168.91.220 http://argocd.lab.home.arpa/
curl -I --cacert ./lab-root-ca.crt --resolve argocd.lab.home.arpa:443:192.168.91.220 https://argocd.lab.home.arpa/
```

The first request must return a 301 to `https://`, the second a 200.

## Certificates (cert-manager)

TLS certificates are issued by cert-manager on behalf of the lab's own certificate authority. It is installed through Argo CD as two applications: `cert-manager` installs cert-manager itself, and `cert-manager-config` installs the issuers and the root certificate.

| Parameter | Value |
| --- | --- |
| cert-manager | v1.21.2 |
| Helm chart | `cert-manager` v1.21.2 from `https://charts.jetstack.io` |
| Namespace | `cert-manager` |
| Release name | `cert-manager` |
| Working issuer | `ClusterIssuer` `lab-ca`: signs certificates with the root |
| Root certificate | `Certificate` `lab-root-ca` (`CN=Lab Root CA`, ECDSA P-256, 10 years), secret `lab-root-ca` in the `cert-manager` namespace |
| Gateway certificate | `Certificate` `lab-wildcard-tls` in the `gateway` namespace: `*.lab.home.arpa`, 90 days, renewed automatically |

The certificate authority is built in three steps (`gitops/cert-manager/issuers.yaml`):

1. `ClusterIssuer` `selfsigned-bootstrap`: an issuer that can only sign itself.
2. `Certificate` `lab-root-ca`: the root certificate issued by that issuer.
3. `ClusterIssuer` `lab-ca`: the working issuer that signs everything else with the root certificate.

Notes:

- The chart values are set right in `gitops/apps/cert-manager.yaml` (`valuesObject`): the chart installs its own CRDs (`crds.enabled: true`), and the controller configuration enables `enableGatewayAPI: true`; without it cert-manager does not watch `Gateway` objects.
- When deploying from scratch, the `cert-manager` namespace is created by `bootstrap.sh`: it is needed for the secret `lab-root-ca` before the chart is installed. The application `cert-manager` still keeps `CreateNamespace=true`.
- The issuers and the root certificate are in a separate application because their CRDs appear only after the chart is installed. That is why `cert-manager-config` has `SkipDryRunOnMissingResource=true` and sync retries enabled.
- The certificate authority is internal: it is not publicly trusted, and ACME (Let's Encrypt) is not used, because the names `*.lab.home.arpa` exist only in the local network.
- The private key of the root certificate lives in the secret `lab-root-ca` in the cluster and in its local copies (see the table below); it is not in Git.

Trust on client machines:

- Browsers and `curl` do not trust the lab certificates until the root certificate is added to the trusted store on the client machine.
- The root certificate (without the key) is exported like this:

  ```sh
  kubectl --kubeconfig ./kubeconfig -n cert-manager get secret lab-root-ca \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
  ```

- When the cluster is re-created, `bootstrap.sh` restores the secret `lab-root-ca` from the local copy (`CA_SECRET`), so the root certificate and `lab-root-ca.crt` stay the same and trust on the clients is preserved.
- If there is no copy (first run, or the file was lost), cert-manager issues the root certificate again with a new key: the old `lab-root-ca.crt` no longer matches, and trust has to be set up again. The script saves the new secret to `CA_SECRET` itself.

Local files (not in VCS):

| File | Contents | Secret |
| --- | --- | --- |
| `~/.lab/lab-root-ca-secret.json` | a copy of the secret `lab-root-ca` together with the private key of the certificate authority; `bootstrap.sh` creates and reads it (the path is the `CA_SECRET` variable) | yes; outside the repository, readable only by the owner |
| `lab-root-ca.crt` (repository root) | the lab root certificate, which is added to the trusted store on client machines | no; kept out of VCS by the `*.crt` pattern in `.gitignore` |
| `lab-root-ca-secret.yaml` (repository root) | an earlier manual export of the same secret; `bootstrap.sh` does not use it | yes; listed in `.gitignore` |

Status check:

```sh
kubectl --kubeconfig ./kubeconfig -n cert-manager get pods
kubectl --kubeconfig ./kubeconfig get clusterissuers
kubectl --kubeconfig ./kubeconfig get certificates -A
```

## Secrets (SOPS)

Platform secrets are stored in Git encrypted. The `sops` utility encrypts them with an age key, and sops-secrets-operator decrypts them in the cluster: it turns `SopsSecret` objects into regular `Secret` objects.

| Parameter | Value |
| --- | --- |
| sops-secrets-operator | 0.21.2 |
| Helm chart | `sops-secrets-operator` 0.28.1 from `https://isindir.github.io/sops-secrets-operator/` |
| Namespace | `sops-secrets-operator` |
| Release name | `sops` |
| Resource type | `SopsSecret` (`isindir.github.com/v1alpha3`) |
| Key in the cluster | secret `sops-age-key-file` (key `key`), mounted into the operator as `/etc/sops-age-key-file/key` (`SOPS_AGE_KEY_FILE`) |
| Key locally | `~/.lab/age.key`: outside the repository, readable only by the owner |
| Encryption rules | `.sops.yaml`: files `*.enc.yaml`, the recipient is the age public key |

Secrets in `gitops/secrets`:

| File | `SopsSecret` | Resulting `Secret` | Purpose |
| --- | --- | --- | --- |
| `argocd-github-oauth.enc.yaml` | `argocd-github-oauth` in the `argocd` namespace | `argocd-github-oauth` | `clientID` and `clientSecret` of the GitHub OAuth app (see "Argo CD login") |
| `alertmanager-config.enc.yaml` | `alertmanager-config` in the `monitoring` namespace | `alertmanager-config` | the Alertmanager configuration, key `alertmanager.yaml` (see "Observability (monitoring)") |
| `talos-backup-s3.enc.yaml` | `talos-backup-s3` in the `talos-backup` namespace | `talos-backup-s3` | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` of the service account `sa-etcd-backup` for uploading etcd snapshots (see "etcd backup") |

How it is built:

- The application `sops-secrets-operator` installs the operator, and the application `platform-secrets` applies the `gitops/secrets` directory. Argo CD puts the `SopsSecret` objects into the cluster as they are, without decrypting them. `platform-secrets` has `SkipDryRunOnMissingResource=true` and sync retries enabled for the case when the operator's CRD is not installed yet.
- Not the whole file is encrypted, only the fields with the `Templates` suffix (`encrypted_suffix` in `.sops.yaml`), that is, the `spec.secretTemplates` section. The kind, name and namespace of the `SopsSecret` object stay readable.
- The age private key is not stored in Git. `bootstrap.sh` puts it into the cluster (secret `sops-age-key-file`) before the root application is applied. The same key is used across all cluster re-creations: if it is lost, there is nothing to decrypt the files in `gitops/secrets` with, and the secrets have to be created again.
- `.sops.yaml` contains only the age public key, which is not a secret.

Working with secrets (requires the `sops` and `age` utilities):

```sh
export SOPS_AGE_KEY_FILE=~/.lab/age.key

# Change an existing secret: sops decrypts it in the editor and encrypts it on save
sops gitops/secrets/alertmanager-config.enc.yaml

# Add a new one: write the SopsSecret manifest in plain text and encrypt it in place
sops --encrypt --in-place gitops/secrets/<name>.enc.yaml
```

The file name must end with `.enc.yaml`, otherwise the rule from `.sops.yaml` does not apply. Before committing, check that `spec.secretTemplates` holds `ENC[...]` values.

Status check:

```sh
kubectl --kubeconfig ./kubeconfig -n sops-secrets-operator get pods
kubectl --kubeconfig ./kubeconfig get sopssecrets -A
```

All `SopsSecret` objects must have the status `Healthy`.

## Observability (monitoring)

Metrics, alerts and dashboards are installed by a single chart, `victoria-metrics-k8s-stack`, through the Argo CD application `monitoring`. VictoriaMetrics is used instead of Prometheus: with the same compatibility it needs noticeably less memory. Log collection is not set up yet (see "Open questions").

| Parameter | Value |
| --- | --- |
| Helm chart | `victoria-metrics-k8s-stack` 0.95.2 from `https://victoriametrics.github.io/helm-charts/` |
| Namespace | `monitoring` |
| Release name | `vmks` (`fullnameOverride: vmks`) |
| Operator | VictoriaMetrics operator v0.75.0 |
| Metrics storage | `VMSingle` `vmks`, VictoriaMetrics v1.153.0, retention 7 days, `emptyDir` volume |
| Metrics collection | `VMAgent` `vmks` v1.153.0 |
| Rules and alerts | `VMAlert` `vmks` v1.153.0 |
| Notifications | Alertmanager v0.34.0 (`VMAlertmanager` `vmks`), by email |
| Dashboards | Grafana 13.2.3 at https://grafana.lab.home.arpa |
| Exporters | node-exporter v1.12.1 (on all three nodes), kube-state-metrics v2.20.0 |

Notes (chart values in `gitops/apps/monitoring.yaml`):

- There is no persistent storage in the cluster (see "Open questions"), so metrics live in `emptyDir`: `storage` is disabled for `VMSingle` and the `data` volume is set explicitly. When the pod `vmsingle-vmks` is re-created, the accumulated metrics are lost.
- Metrics collection for etcd, the scheduler, the controller manager and kube-proxy is disabled (`kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`): there is no kube-proxy in the cluster (Cilium replaces it), and metrics of the other three components are not collected.
- Argo CD creates the `monitoring` namespace (`CreateNamespace=true`) with the label `pod-security.kubernetes.io/enforce: privileged`: node-exporter reads host data, and Talos applies the `baseline` profile by default.
- The application has `ServerSideApply=true` enabled: the operator's resource type definitions are too large for a regular `apply`.
- The chart generates the Grafana admin password anew on every render, so the field `/data/admin-password` of the secret `vmks-grafana` is excluded from comparison (`ignoreDifferences` and `RespectIgnoreDifferences=true`). Otherwise the application would always be `OutOfSync`.
- Grafana is published through the shared gateway: `HTTPRoute` `grafana` in the `monitoring` namespace (`gitops/gateway/grafana-route.yaml`); the service `vmks-grafana:80` stays `ClusterIP`.

Alerts and notifications:

- Alertmanager takes its configuration from the secret `alertmanager-config` (`alertmanager.spec.configSecret`), not from the chart values. sops-secrets-operator creates the secret from `gitops/secrets/alertmanager-config.enc.yaml`: the configuration contains the mail server address and password, so it is encrypted in Git.
- The default receiver is `email`: messages go out over SMTP. Alerts are grouped by `alertname` and `namespace` and repeated every 4 hours.
- Alerts with `severity = "info"` and the service alert `InfoInhibitor` go to the `blackhole` receiver, so no emails are sent for them.
- `Watchdog` (an always-firing check alert) is sent once a minute to an external webhook, the `deadmans-switch` receiver. If the signals stop arriving, the monitoring itself is down.
- To change receivers or routes, edit the encrypted file with `sops` (see "Secrets (SOPS)") and push a commit to `main`.

Grafana login: user `admin`, the password is in the secret `vmks-grafana`:

```sh
kubectl --kubeconfig ./kubeconfig -n monitoring get secret vmks-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Status check:

```sh
kubectl --kubeconfig ./kubeconfig -n monitoring get pods
kubectl --kubeconfig ./kubeconfig -n monitoring get vmsingle,vmagent,vmalert,vmalertmanager
```

## etcd backup

etcd snapshots are taken by [talos-backup](https://github.com/siderolabs/talos-backup), a Sidero Labs utility that runs in the cluster as a `CronJob`, gets a snapshot through the Talos API and uploads it to S3. The manifests are in the `gitops/talos-backup` directory; the Argo CD application is `talos-backup`.

| Parameter | Value |
| --- | --- |
| Image | `ghcr.io/siderolabs/talos-backup:v0.1.0-beta.3-10-gb9fd478` |
| Namespace | `talos-backup` |
| Schedule | `15 */3 * * *`: every 3 hours; a missed run is caught up within an hour, concurrent runs are forbidden |
| Destination | bucket `lab-etcd-backup-2a7416`, keys of the form `etcd/lab-<UTC time>.snap.zst.age` |
| Processing | zstd compression, then age encryption with a dedicated backup key |
| Retention | 30 days; for the first 14 days a snapshot can be neither deleted nor overwritten (Object Lock, see "Cloud storage (cloud.ru)") |
| RPO | up to 3 hours (the interval between snapshots) |
| Restore | runbook [docs/runbooks/etcd-restore.md](docs/runbooks/etcd-restore.md), last tested 2026-10-11 |

How it is built:

- Access to the Talos API from the pod is allowed by the `KubeTalosAPIAccessConfig` document in the control plane machine config (`main.tf`): only the `talos-backup` namespace and only the `os:etcd:backup` role. Nothing except an etcd snapshot can be done with this access.
- The Talos `ServiceAccount` object (`talos.dev/v1alpha1`, `talos-serviceaccount.yaml`) requests this role. From it Talos creates the secret `talos-backup-secrets` with a config for API access; it is mounted into the pod at `/var/run/secrets/talos.dev`.
- The bucket access keys are in the secret `talos-backup-s3`, which sops-secrets-operator creates from `gitops/secrets/talos-backup-s3.enc.yaml` (see "Secrets (SOPS)"). These are the keys of the cloud.ru service account `sa-etcd-backup`.
- The snapshot is encrypted with the age public key written in `cronjob.yaml` (`AGE_RECIPIENT_PUBLIC_KEY`). This is a separate key, not the one the secrets in Git are encrypted with. The private key is kept only locally in `~/.lab/etcd-backup.age.key` and in Bitwarden; it is not in the cluster, so access to the cluster or to the bucket is not enough to read a snapshot. If the key is lost, there is nothing to decrypt the snapshots with.
- The pod runs as non-root with all capabilities dropped; it requests 50m CPU and 64 MiB of memory, with a memory limit of 512 MiB. The job is terminated after 15 minutes and retried twice.
- A snapshot takes about 27 MB, and about 3 MB after compression and encryption.

Alerts (`VMRule` `talos-backup` in the `monitoring` namespace, `gitops/talos-backup/alerts.yaml`):

| Alert | Condition |
| --- | --- |
| `EtcdBackupTooOld` | the last successful snapshot is older than 16 hours (for 15 minutes). The threshold is above the interval because the cluster is shut down overnight |
| `EtcdBackupNeverSucceeded` | the `CronJob` has had no successful run for 12 hours |

Both are `warning` level and arrive by email. A failed job is additionally caught by the standard `KubeJobFailed` alert from the monitoring chart.

Restore:

- The procedure is in the runbook [docs/runbooks/etcd-restore.md](docs/runbooks/etcd-restore.md): picking and decrypting a snapshot, wiping the `EPHEMERAL` partition on the control plane, `talosctl bootstrap --recover-from`, restarting Cilium, cleaning up stale objects, verification.
- Snapshots are downloaded and decrypted in the `.restore/` directory in the repository root (listed in `.gitignore`). A decrypted snapshot contains all the cluster secrets: it has to be deleted after the restore.
- A snapshot fits only a cluster with the same Talos secrets (they live in the Terraform state). If the cluster was re-created with new secrets, the node certificates will not match the snapshot.
- After a restore, always restart Cilium on all nodes (`kubectl -n kube-system rollout restart ds/cilium`): while the API server is unavailable, the agents on the worker nodes lose the address of the `kubernetes` service and do not bring it back themselves. The nodes stay `Ready` and the Argo CD applications stay `Healthy`, while pods on the worker nodes cannot reach the API.
- Restore drill on 2026-10-11 (wipe of `EPHEMERAL` on `talos-cp1`, snapshot from S3): the control plane was back in 5 minutes, and the fully working state took 40 minutes including diagnosis. As a result, the Cilium restart and the cleanup of stale objects were added to the runbook.

Status check and a manual snapshot run:

```sh
kubectl --kubeconfig ./kubeconfig -n talos-backup get cronjob,jobs
kubectl --kubeconfig ./kubeconfig -n talos-backup create job --from=cronjob/talos-backup manual-$(date +%s)
aws --profile cloudru --endpoint-url https://s3.cloud.ru s3 ls s3://lab-etcd-backup-2a7416/etcd/
```

## Load balancing (MetalLB)

`LoadBalancer` services get external addresses from MetalLB. It is installed through Argo CD as two applications: `metallb` installs MetalLB itself, and `metallb-config` installs its settings.

| Parameter | Value |
| --- | --- |
| MetalLB | v0.16.1 |
| Helm chart | `metallb` 0.16.1 from `https://metallb.github.io/metallb` |
| Namespace | `metallb-system` |
| Mode | L2 (ARP) |
| Address pool | `lan`: 192.168.91.220–192.168.91.230, auto-assignment enabled |
| Advertisement | `L2Advertisement` `lan` for the pool `lan` |

Notes:

- The chart values are not overridden; the default configuration is used.
- Argo CD creates the `metallb-system` namespace (`CreateNamespace=true`) with the label `pod-security.kubernetes.io/enforce: privileged`: the speaker runs in the host network, and Talos applies the `baseline` profile by default.
- `IPAddressPool` and `L2Advertisement` are in a separate application because their CRDs appear only after the chart is installed. That is why `metallb-config` has `SkipDryRunOnMissingResource=true` and sync retries enabled.
- The pool addresses must not overlap with the router's DHCP range or with the node addresses.
- The address 192.168.91.220 is pinned to the gateway service `cilium-gateway-lab` by the annotation `metallb.io/loadBalancerIPs`; the other pool addresses are free.

Status check:

```sh
kubectl --kubeconfig ./kubeconfig -n metallb-system get pods
kubectl --kubeconfig ./kubeconfig -n metallb-system get ipaddresspools,l2advertisements
kubectl --kubeconfig ./kubeconfig get svc -A | grep LoadBalancer
```

## Resources

The resource budget available on Proxmox:

| Resource | Amount |
| --- | --- |
| vCPU | 12 |
| RAM | 16 GB |

All MVP virtual machines must fit into this budget.

Current allocation (set in `terraform.tfvars`):

| Node | vCPU | RAM | Disk |
| --- | --- | --- | --- |
| `talos-cp1` | 2 | 4 GB | 20 GB |
| `talos-w1` | 4 | 5 GB | 20 GB |
| `talos-w2` | 4 | 5 GB | 20 GB |
| **Total** | **10** | **14 GB** | **60 GB** |

The remainder, 2 vCPU and 2 GB of RAM, is left for Proxmox overhead.

## Open questions

To be decided later:

- the final resource allocation between the VMs (the current one is in "Resources");
- storage in the cluster (there is none yet, so VictoriaMetrics metrics live in `emptyDir`);
- log collection (metrics and alerts are already in place, see "Observability (monitoring)");
- the mechanism for starting and resetting trainer scenarios.

## Status

The Talos cluster `lab` (1 control plane and 2 worker nodes) is deployed by the `bootstrap.sh` script and is running. The cluster has Cilium, Argo CD, MetalLB, Gateway API, cert-manager, sops-secrets-operator, a VictoriaMetrics monitoring stack and etcd backup (`talos-backup`) installed. The applications `root`, `argocd`, `cilium`, `metallb`, `metallb-config`, `gateway-api-crds`, `gateway`, `cert-manager`, `cert-manager-config`, `sops-secrets-operator`, `platform-secrets`, `monitoring` and `talos-backup` are `Synced` and `Healthy`. The only `LoadBalancer` service is the gateway `lab` (192.168.91.220); through it Argo CD (https://argocd.lab.home.arpa, GitHub login), Hubble UI (https://hubble.lab.home.arpa) and Grafana (https://grafana.lab.home.arpa) are available over HTTPS from the local network, and HTTP requests are redirected to HTTPS. Alerts arrive by email. The Terraform state is stored in cloud.ru Object Storage; encrypted etcd snapshots are uploaded there every 3 hours, and restore from a snapshot was tested on 2026-10-11. Application components and the remaining open questions are still ahead.

## Changelog

- 2026-10-03: Proxmox VE upgraded to version 9.2.21.
- 2026-10-03: static IP addresses of the Talos nodes fixed on the router: master 192.168.91.201, worker nodes 192.168.91.211 and 192.168.91.212.
- 2026-10-03: the Talos cluster `lab` brought up by hand: Talos v1.14.2, Kubernetes v1.37.1, all three nodes `Ready`.
- 2026-10-05: the cluster `lab` re-created with Terraform (providers `bpg/proxmox` and `siderolabs/talos`): Talos v1.14.2, Kubernetes v1.37.0, nodes `talos-cp1`, `talos-w1`, `talos-w2`. Provisioning moved from open questions to decisions made.
- 2026-10-05: Argo CD v3.5.3 (chart `argo-cd` 10.9.6) installed in the cluster, and the root application `root` created following the app of apps pattern. Application delivery moved from open questions to decisions made.
- 2026-10-06: MetalLB v0.16.1 (chart `metallb` 0.16.1) installed through Argo CD in L2 mode with the address pool 192.168.91.220–192.168.91.230. Load balancing moved from open questions to decisions made.
- 2026-10-07: the cluster CNI replaced with Cilium v1.20.2 (chart `cilium` 1.20.2) with Hubble: the built-in Flannel and kube-proxy are disabled in the machine config, and the Argo CD application `cilium` was added. CNI moved from open questions to decisions made.
- 2026-10-07: the `bootstrap.sh` script added; it brings the cluster up from scratch (Terraform, Cilium, Argo CD, the repository access secret, the root application). The cluster `lab` was re-created with this script.
- 2026-10-07: the QEMU guest agent device enabled on the VMs: without it, nodes with the `qemu-guest-agent` extension stayed in the `Booting` stage.
- 2026-10-07: Gateway API v1.6.1 implemented by Cilium installed: Argo CD applications `gateway-api-crds` and `gateway`, the gateway `lab` on 192.168.91.220 (HTTP, `*.lab.home.arpa`). Argo CD and Hubble UI published under the names `argocd.lab.home.arpa` and `hubble.lab.home.arpa`; `argocd-server` switched to running without TLS. Installation of the Gateway API CRDs before Cilium added to `bootstrap.sh`. Ingress moved from open questions to decisions made.
- 2026-10-08: cert-manager v1.21.2 (chart `cert-manager` v1.21.2) installed through Argo CD with Gateway API support, and the lab's own certificate authority created: `ClusterIssuer` `selfsigned-bootstrap`, the root certificate `lab-root-ca`, the working issuer `lab-ca`.
- 2026-10-08: the gateway `lab` switched to HTTPS: the `https` listener (port 443) added with the certificate `*.lab.home.arpa` from `lab-ca`, the routes `argocd` and `hubble` attached to it, and HTTP kept only for the redirect to HTTPS (`HTTPRoute` `http-to-https`). TLS for inbound traffic moved from open questions to decisions made.
- 2026-10-08: `bootstrap.sh` keeps the lab root certificate across cluster re-creations: the secret `lab-root-ca` is restored from the local copy (`CA_SECRET`, `~/.lab/lab-root-ca-secret.json` by default) before cert-manager starts, and on the first run without a copy it is saved there. The script also checks the environment before starting (utilities, including `jq`, and the deploy key) and does not reinstall the Gateway API CRDs, Cilium or Argo CD on a running cluster; the Gateway API version moved to the `GATEWAY_API_VERSION` variable.
- 2026-10-08: sops-secrets-operator 0.21.2 (chart `sops-secrets-operator` 0.28.1) installed through Argo CD: secrets are stored in Git encrypted by `sops` with an age key. `bootstrap.sh` checks that the key exists (`AGE_KEY`, `~/.lab/age.key` by default) and puts it into the cluster as the secret `sops-age-key-file`.
- 2026-10-09: the `.sops.yaml` encryption rules and the application `platform-secrets` with the `gitops/secrets` directory added. Argo CD login switched to GitHub OAuth through Dex (secret `argocd-github-oauth`), the local `admin` account disabled, permissions granted in `configs.rbac`.
- 2026-10-10: the monitoring stack installed through Argo CD: chart `victoria-metrics-k8s-stack` 0.95.2 (VictoriaMetrics v1.153.0, Alertmanager, Grafana 13.2.3), application `monitoring`. Metrics are kept for 7 days in `emptyDir`. Grafana published at https://grafana.lab.home.arpa. The Alertmanager configuration is stored in the encrypted secret `alertmanager-config`: notifications go by email, and `info` level alerts are not sent. Metrics and alerts moved from open questions to decisions made; log collection stays open.
- 2026-10-10: the `*.crt` pattern added to `.gitignore`: `lab-root-ca.crt` can no longer end up in the repository.
- 2026-10-11: the buckets `lab-tfstate-2a7416` (Terraform state, versioning) and `lab-etcd-backup-2a7416` (etcd snapshots: versioning, Object Lock for 14 days, deletion after 30 days) created in cloud.ru Object Storage. They are described by a separate Terraform configuration in the `cloud/` directory.
- 2026-10-11: the Terraform state moved from local files to the bucket `lab-tfstate-2a7416`: the cluster under the key `talos/terraform.tfstate` (`backend.tf`), the buckets under `cloud/terraform.tfstate` (`cloud/backend.tf`), locking via `use_lockfile`.
- 2026-10-11: `.envrc` for direnv added: `KUBECONFIG`, `TALOSCONFIG`, `SOPS_AGE_KEY_FILE`, `AWS_PROFILE` and `TF_INPUT`. The Proxmox token comes from the system keyring through `.envrc.local` (in `.gitignore`); the `lab-secrets-sync` script puts it into the keyring from Bitwarden.
- 2026-10-11: etcd backup set up: `talos-backup` (a `CronJob` in the `talos-backup` namespace, Argo CD application `talos-backup`) takes a snapshot every 3 hours, compresses it with zstd, encrypts it with age and uploads it to the bucket `lab-etcd-backup-2a7416`. `KubeTalosAPIAccessConfig` added to the control plane machine config (role `os:etcd:backup` for the `talos-backup` namespace); the bucket access keys are in the encrypted secret `talos-backup-s3`; alerts `EtcdBackupTooOld` and `EtcdBackupNeverSucceeded`. etcd backup moved from open questions to decisions made.
- 2026-10-11: a restore drill of etcd from a snapshot carried out, and the runbook `docs/runbooks/etcd-restore.md` written from its results. The `.restore/` directory added to `.gitignore`.
- 2026-10-13: `KUBECONFIG` in `.envrc` now points at `~/.kube/home/lab` (a copy of the kubeconfig outside the repository, readable only by the owner) instead of `./kubeconfig`. `bootstrap.sh` still exports the file to the repository root.
- 2026-10-13: Argo CD permissions switched from a personal email address to a GitHub team: only members of the organization `oncall-gym` can log in (`orgs` in the Dex connector), and `role:admin` is granted to the team `oncall-gym:admins`.
- 2026-10-13: the documentation (`README.md`, `AGENTS.md`) and the comments in the code translated into English ahead of opening the repository; the documentation language is now English.
