# etcd backup

[talos-backup](https://github.com/siderolabs/talos-backup) runs as a `CronJob` in the `talos-backup` namespace, takes an etcd snapshot through the Talos API, compresses and encrypts it, and uploads it to S3. Manifests: `gitops/talos-backup/`.

| Parameter | Value |
| --- | --- |
| Schedule | `15 */3 * * *`; a missed run is caught up within an hour, no concurrent runs |
| Destination | `s3://lab-etcd-backup-2a7416/etcd/lab-<UTC time>.snap.zst.age` |
| Processing | zstd, then age encryption with a dedicated backup key |
| Retention | 30 days; locked against deletion for the first 14 (Object Lock) |
| RPO | 3 hours |
| Size | about 27 MB raw, about 3 MB stored |

## Access

- **Talos API.** `KubeTalosAPIAccessConfig` in the control plane config allows API access from the `talos-backup` namespace with the `os:etcd:backup` role only. The Talos `ServiceAccount` in `talos-serviceaccount.yaml` requests that role, and Talos creates a secret with matching credentials that is mounted into the pod.
- **S3.** The job uses the keys of a separate cloud.ru service account, stored in the encrypted secret `talos-backup-s3`. The keys can upload objects but cannot list or download them, and have no access to other buckets (verified on 2026-10-17: every read request returns 403). Deletion was not tested; for the first 14 days Object Lock prevents it anyway.
- **Encryption.** Snapshots are encrypted to the age public key in `cronjob.yaml`. This is not the SOPS key: the private key is kept only by the operator, outside the cluster, so neither cluster access nor bucket access is enough to read a snapshot.
- The pod runs as non-root with all capabilities dropped.

## Alerts

| Alert | Fires when |
| --- | --- |
| `EtcdBackupTooOld` | the last successful snapshot is older than 16 hours. The threshold is well above the 3-hour interval because the lab is shut down overnight |
| `EtcdBackupNeverSucceeded` | the `CronJob` has had no successful run for 12 hours |

Failed jobs also trigger the standard `KubeJobFailed` alert.

## Restore

Follow [runbooks/etcd-restore.md](runbooks/etcd-restore.md). Key points:

- A snapshot fits only a cluster with the same Talos secrets, which live in the Terraform state.
- Decrypted snapshots contain every cluster secret. Work in the git-ignored `.restore/` directory and delete them afterwards.
- After a restore, restart Cilium on all nodes. Worker agents lose the address of the `kubernetes` service while the API server is down; nodes stay `Ready` and applications look `Healthy`, but pods on workers cannot reach the API.

The procedure was drilled on 2026-10-11 by wiping etcd on `talos-cp1` and restoring from S3: the control plane was back in 5 minutes, and the cluster was fully healthy after 40 minutes including diagnosis. The Cilium restart and the cleanup of stale objects were added to the runbook as a result.

## Checks

```sh
kubectl --kubeconfig ./kubeconfig -n talos-backup get cronjob,jobs
kubectl --kubeconfig ./kubeconfig -n talos-backup create job --from=cronjob/talos-backup manual-$(date +%s)
aws --endpoint-url https://s3.cloud.ru s3 ls s3://lab-etcd-backup-2a7416/etcd/
```
