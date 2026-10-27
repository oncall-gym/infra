# Deployment from scratch

`bootstrap.sh` brings up the whole cluster with one command. It installs only what has to exist before Argo CD can take over; everything else comes from Git.

## Requirements

- `terraform`, `kubectl`, `helm` and `jq`; `terraform init` done in `terraform/cluster/`.
- A filled-in `terraform/cluster/terraform.tfvars` and the Proxmox API token in `TF_VAR_proxmox_api_token` (see [provisioning.md](provisioning.md#local-environment)).
- The AWS CLI profile with access to the state bucket.
- The Talos ISO in Proxmox storage (`local:iso/talos.iso`).
- Access to `github.com` (the Gateway API CRDs are downloaded from there).
- The private deploy key that lets Argo CD read this repository: `DEPLOY_KEY`, default `~/argocd-deploy-key`.
- The age private key the secrets in `gitops/secrets` are encrypted with: `AGE_KEY`, default `~/.lab/age.key`. The script refuses to start without it: a new key could not decrypt the secrets in Git.
- Optionally, a saved copy of the CA secret: `CA_SECRET`, default `~/.lab/lab-root-ca-secret.json`. Without it a new CA is issued, and the script saves it there.

## Steps

1. Check the environment before changing anything.
2. `terraform apply -parallelism=1`: VMs and the Talos cluster.
3. Export `kubeconfig` and `talosconfig` to the repository root and wait for the API server.
4. Install the Gateway API CRDs with `kubectl apply --server-side`, unless they are already there. They must exist before Cilium starts, or the Cilium operator does not create its `GatewayClass`.
5. Install Cilium with Helm (values from `gitops/cilium/values.yaml`) and wait for the nodes to become `Ready`.
6. Install Argo CD with Helm (values from `gitops/argocd/values.yaml`).
7. Create the repository secret `repo-local-infra` with the deploy key.
8. Create the `cert-manager` namespace and restore the CA secret `lab-root-ca` from the saved copy, before cert-manager exists; otherwise cert-manager would issue a new root certificate.
9. Create the secret `sops-age-key-file` with the age key for sops-secrets-operator.
10. Apply `gitops/root.yaml`. From here Argo CD installs the rest and takes over the Cilium and Argo CD releases.
11. If there was no saved CA copy, wait for cert-manager to issue one and save it to `CA_SECRET`.

```sh
./bootstrap.sh
```

## Re-running

The script is safe on a running cluster. It skips the CRDs if they exist, skips the Cilium and Argo CD Helm installs if Argo CD already has applications with those names, and never overwrites an existing `lab-root-ca`. These checks keep the script from fighting Argo CD over components already handed to it.

## Versions set twice

Some versions appear both in the script and in an Argo CD application, and must match; otherwise Argo CD moves the release to the Git version right after bootstrap:

| Script variable | Application |
| --- | --- |
| `GATEWAY_API_VERSION` | `gitops/apps/gateway-api-crds.yaml` (also must match the version Cilium is built against) |
| `CILIUM_VERSION` | `gitops/apps/cilium.yaml` |
| `ARGOCD_VERSION` | `gitops/apps/argocd.yaml` |

## After bootstrap

GitHub login to Argo CD works once Argo CD has deployed sops-secrets-operator and the secret `argocd-github-oauth` exists. Until then, check progress with `kubectl -n argocd get applications`.
