# AGENTS.md

Rules for AI coding agents working in this repository.

## Context

Local infrastructure for the MVP of a DevOps troubleshooting trainer: a Talos Linux cluster on Proxmox VE, provisioned with Terraform and run with Argo CD. [README.md](README.md) is the single source of truth: the decisions made, the current state of every component, and the open questions. Read the relevant section before changing anything.

The decisions listed in the README are not revisited without an explicit request from the user. The open questions (storage in the cluster, log collection, the scenario mechanism, the final resource allocation) are not decided yet: offer options with a recommendation and let the user choose.

## Working rules

- **Change infrastructure through code.** VMs and Talos machine configs through Terraform in the root, the cloud.ru buckets through Terraform in `cloud/`, cluster components through an `Application` in `gitops/apps`. No manual changes in Proxmox, the cloud.ru console, `talosctl apply-config`, `kubectl apply` or `helm install`: Argo CD reverts them and the Terraform state drifts. Never edit the state by hand.
- **Talos is immutable.** No SSH, no shell, no packages: only the Talos API and declarative configs.
- **Keep secrets out of Git.** A secret that has to reach the cluster goes into a `SopsSecret` in `gitops/secrets/<name>.enc.yaml`, encrypted with `sops`; check that `spec.secretTemplates` holds only `ENC[...]` values before committing. Never commit or print kubeconfigs, talosconfigs, Terraform state, `terraform.tfvars`, `.envrc.local`, private keys (age, SSH, the CA), access keys, tokens, etcd snapshots or decrypted secrets. `.envrc` holds only paths and non-secret settings.
- **Respect the fixed network plan.** Node addresses, the MetalLB pool and the gateway address are listed in the README; do not reuse or change them.
- **Publish HTTP services through the shared gateway** `lab` with an `HTTPRoute` on the `https` listener and a name under `lab.home.arpa`; certificates come only from the `ClusterIssuer` `lab-ca`. Remind the user to add the DNS record.
- **Keep duplicated versions in sync.** The Gateway API, Cilium and Argo CD versions are set both in `bootstrap.sh` and in the matching `Application`.
- **Stay within the resource budget** of 12 vCPU and 16 GB of RAM for all VMs.
- **Settings that look removable but are not.** The README explains each of them: the QEMU guest agent device, the Talos API access for `talos-backup`, the existence checks in `bootstrap.sh`, `server.insecure` in Argo CD, `enableGatewayAPI` in cert-manager, the `skip_*` flags for cloud.ru, the AWS CLI lifecycle rule, the `ServerSideApply` and `ignoreDifferences` settings of the `monitoring` application, deploy keys being allowed in the GitHub organization. Do not remove or weaken access rules (Argo CD RBAC, Talos roles, backup encryption) unless the user asks.
- **Keep it simple.** This is an MVP: no components or abstractions "for the future".
- **Keep the README current** when something changes or an open question is decided. Documentation, comments and script output are in English: the repository is public.
- **Commits are authored by the user only**: no `Co-Authored-By` lines or other agent attribution.

## Actions that need confirmation

Anything that changes Proxmox, cloud.ru or the cluster runs only after explicit confirmation from the user: `bootstrap.sh`, `terraform apply`/`destroy`, `kubectl apply`/`delete`, `helm install`/`upgrade`, node resets and upgrades, etcd restores, manual Argo CD syncs.

A push to `main` also changes the cluster, because Argo CD applies `gitops/` automatically: never `git push` without an explicit request.
