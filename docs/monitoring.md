# Monitoring

Metrics, alerts and dashboards come from one chart, `victoria-metrics-k8s-stack`, installed by the application `monitoring` (values inline in `gitops/apps/monitoring.yaml`, release `vmks`). VictoriaMetrics replaces Prometheus: it is compatible and needs noticeably less memory. Logs are not collected yet.

| Component | Role |
| --- | --- |
| `VMSingle` | metrics storage, 7 days |
| `VMAgent` | scraping |
| `VMAlert` | recording and alerting rules |
| Alertmanager | notifications by email |
| Grafana | dashboards at https://grafana.lab.home.arpa |
| node-exporter, kube-state-metrics | node and object metrics |

## Configuration notes

- There is no persistent storage in the cluster yet, so `VMSingle` keeps its data in `emptyDir`: metrics are lost when the pod is re-created.
- Scraping of etcd, the scheduler, the controller manager and kube-proxy is disabled. There is no kube-proxy (Cilium replaces it), and the other three are not scraped.
- The `monitoring` namespace is labelled `pod-security.kubernetes.io/enforce: privileged`, because node-exporter reads host data.
- `ServerSideApply=true`: the operator's CRDs are too large for a regular apply.
- The chart generates a new Grafana admin password on every render, so `/data/admin-password` of the secret `vmks-grafana` is excluded from comparison (`ignoreDifferences` with `RespectIgnoreDifferences=true`). Without that the application would always be `OutOfSync`. The current password is in that secret.

## Alerting

Alertmanager reads its configuration from the encrypted secret `alertmanager-config` rather than from the chart values, because it contains the SMTP password (see [secrets.md](secrets.md)).

- Default receiver: email. Alerts are grouped by `alertname` and `namespace` and repeated every 4 hours.
- `severity = "info"` alerts and `InfoInhibitor` go to a `blackhole` receiver.
- `Watchdog` fires constantly and is sent every minute to an external dead man's switch: if it stops arriving, monitoring itself is down.

## Checks

```sh
kubectl --kubeconfig ./kubeconfig -n monitoring get pods
kubectl --kubeconfig ./kubeconfig -n monitoring get vmsingle,vmagent,vmalert,vmalertmanager
```
