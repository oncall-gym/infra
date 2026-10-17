# Runbook: restore etcd from backup

| | |
|---|---|
| **Applies to** | Talos cluster `lab` (1 control plane: `talos-cp1` / 192.168.91.201, 2 workers) |
| **Use when** | etcd data is lost or corrupted; the control plane node was rebuilt; a bad change must be rolled back cluster-wide |
| **Backups** | `talos-backup` CronJob, every 3 h → `s3://lab-etcd-backup-2a7416/etcd/` (cloud.ru, Object Lock 14 d, expiry 30 d) |
| **RPO** | ≤ 3 h (backup interval) |
| **RTO** | ~10 min following this runbook (measured: see [Drill history](#drill-history)) |
| **Last tested** | 2026-10-11 |

## How backups work

1. `talos-backup` (namespace `talos-backup`) calls the Talos API with a role-scoped
   token (`os:etcd:backup` only), enabled by `KubeTalosAPIAccessConfig` on the control plane.
2. The snapshot is compressed with zstd and encrypted with **age** to a dedicated
   backup key. The private key is **never** in the cluster.
3. Uploaded with the `sa-etcd-backup` service account key (SopsSecret `talos-backup-s3`).
4. Alerts: `EtcdBackupTooOld` (> 16 h without success), `EtcdBackupNeverSucceeded`, `KubeJobFailed`.

## Prerequisites

- `talosctl`, `kubectl`, `aws`, `age`, `zstd` installed; run from the repository root (direnv sets
  `TALOSCONFIG`, `KUBECONFIG`, `AWS_PROFILE`).
- Backup private key: `~/.lab/etcd-backup.age.key` (master copy in the password manager).
- cloud.ru access: profile `cloudru` in `~/.aws/credentials`.
- Talos machine secrets are unchanged (they live in Terraform state in S3). If the whole
  cluster was rebuilt with **new** secrets, the snapshot will not match the node certificates.

## Procedure

### 0. Prepare

- Pause the Better Stack heartbeat (the dead man's switch will fire otherwise).
- Work in a git-ignored directory: `mkdir -p .restore && cd .restore` in the repository root.

### 1. Pick and decrypt a snapshot

```bash
aws --profile cloudru --endpoint-url https://s3.cloud.ru \
  s3 ls s3://lab-etcd-backup-2a7416/etcd/ --human-readable | tail
SNAP=lab-<timestamp>.snap.zst.age
aws --profile cloudru --endpoint-url https://s3.cloud.ru \
  s3 cp "s3://lab-etcd-backup-2a7416/etcd/$SNAP" .
age -d -i ~/.lab/etcd-backup.age.key "$SNAP" | zstd -d > lab.snap
ls -l lab.snap        # tens of MB; size is logged by the backup job
```

### 2. Wipe etcd on the control plane

Skip if the node is freshly installed and waiting for bootstrap.

```bash
date   # start of outage, for RTO
talosctl -n 192.168.91.201 reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
talosctl -n 192.168.91.201 service etcd   # wait for STATE: Preparing
```

`EPHEMERAL` holds etcd data and container state. Machine config lives in `STATE`
and survives, so the node comes back with the same identity.

### 3. Bootstrap from the snapshot

```bash
talosctl -n 192.168.91.201 bootstrap --recover-from=./lab.snap
talosctl -n 192.168.91.201 service etcd   # STATE: Running, HEALTH: OK
kubectl get nodes                         # API returns in ~1 min; all nodes Ready
```

Expected output of `bootstrap`: `recovering from snapshot ... hash ..., revision ..., total keys ...`.

### 4. Restart Cilium on all nodes. Do not skip this step.

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

**Why:** while the API server is down, the `kubernetes` Service has no endpoints and
Cilium agents on the workers drop the backend for `10.96.0.1:443`. After the API
returns they do **not** re-add it. Pods on workers then time out talking to the API.
Nodes stay `Ready` and `cilium status` reports `OK`, so nothing looks wrong at first.
Found during the 2026-10-11 drill.

Verify on every node:

```bash
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  p=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$n -o name)
  echo "== $n"
  kubectl -n kube-system exec $p -c cilium-agent -- cilium-dbg service list | grep -A1 '10.96.0.1:443'
done
# each node must show: 1 => 192.168.91.201:6443/TCP (active)
```

### 5. Clean up stale objects from the snapshot

The snapshot records pods and jobs as they were at snapshot time.

```bash
kubectl get pods -A | grep -v -E 'Running|Completed'   # delete stuck Pending/Unknown/Terminating pods
kubectl -n talos-backup get jobs                       # jobs running at snapshot time end up Failed
```

Delete stuck pods (their controllers recreate them) and failed backup jobs.

### 6. Verify

```bash
kubectl -n argocd get applications          # all Synced / Healthy
kubectl get sopssecrets -A                  # all Healthy
kubectl -n monitoring get pods              # no CrashLoopBackOff
```

Open https://argocd.lab.home.arpa and https://grafana.lab.home.arpa. Metric history restarts
from zero, because VMSingle uses `emptyDir`.

**Do not stop at "Argo CD is green".** During the drill every app was Healthy 5 minutes
after bootstrap while pods on the workers could not reach the API. Steps 4 and 5 are the
real check.

### 7. Take a fresh backup and finish

```bash
kubectl -n talos-backup create job --from=cronjob/talos-backup post-restore-$(date +%s)
shred -u lab.snap *.age
date   # end of outage
```

Resume the Better Stack heartbeat. Record the drill below.

## Drill history

| Date | Scenario | Snapshot age at restore (RPO) | Control plane back | Fully healthy | Findings |
|---|---|---|---|---|---|
| 2026-10-11 | Wipe EPHEMERAL on cp1, recover from S3 snapshot | ~3 min | 5 min (22:08 → 22:13) | 40 min (22:08 → 22:48), including diagnosis | Cilium on both workers lost the `kubernetes` Service backend; stale CoreDNS pod Pending; backup jobs running at snapshot time marked Failed. Added steps 4 and 5. Canary ConfigMap restored, namespace created after the snapshot gone: point-in-time restore confirmed. |

## Next drill ideas

- Full rebuild: `terraform destroy` + `terraform apply` with bootstrap from snapshot (requires
  skipping the regular `talos_machine_bootstrap`).
- Restore from a different machine, using only the password manager and these docs.
