# Application delivery (Argo CD)

Argo CD keeps the cluster in sync with the `gitops/` directory of the `main` branch. `bootstrap.sh` installs it once; after that Argo CD manages its own Helm release.

## Layout

The root application `gitops/root.yaml` applies every `Application` in `gitops/apps/`. Each application either installs a Helm chart (values in `gitops/<component>/values.yaml` or inline in the manifest) or applies a directory of manifests.

| Application | What it installs |
| --- | --- |
| `argocd` | Argo CD itself |
| `cilium` | CNI, Gateway API implementation, Hubble |
| `gateway-api-crds` | Gateway API CRDs |
| `gateway` | the shared gateway and HTTP routes (`gitops/gateway`) |
| `metallb`, `metallb-config` | MetalLB and its address pool |
| `cert-manager`, `cert-manager-config` | cert-manager and the lab CA |
| `sops-secrets-operator`, `platform-secrets` | the operator and the encrypted secrets |
| `monitoring` | VictoriaMetrics, Alertmanager, Grafana |
| `talos-backup` | etcd backups and their alerts |

To add a component, put an `Application` manifest into `gitops/apps/` and push to `main`.

## Behaviour

- Every application syncs automatically with `prune` and `selfHeal`: manual changes are reverted, and anything deleted from Git is deleted from the cluster. `gateway-api-crds` has no `prune`, so CRDs are never removed automatically.
- Configuration that depends on CRDs from a chart (`*-config`, `platform-secrets`) lives in a separate application with `SkipDryRunOnMissingResource=true` and retries, so it waits for the chart.
- `argocd-server` runs without TLS (`server.insecure: true`): TLS terminates at the gateway.
- The notifications controller is disabled to save memory.

## Repository access

Argo CD reads this repository over SSH with a read-only deploy key stored in the secret `repo-local-infra` (created by `bootstrap.sh`, not in Git). The secret's `url` must match the `repoURL` of the applications.

Deploy keys must stay allowed in the `oncall-gym` organization settings. If they are disabled, GitHub silently disables the key: the applications keep running, but changes from Git stop reaching the cluster (sync status `Unknown`, error `repository not found`).

## Login and permissions

The Argo CD UI is at https://argocd.lab.home.arpa. Users log in with GitHub through the built-in Dex; the local `admin` account is disabled. The settings are in `gitops/argocd/values.yaml`.

- Only members of the GitHub organization `oncall-gym` can log in (`orgs` in the Dex connector).
- There is no default role. `role:admin` is granted to the team `oncall-gym:admins` in `policy.csv`; Dex passes teams as `<org>:<team>`. Access is managed by team membership in GitHub, not in Git.
- To give another team access, add `g, oncall-gym:<team>, <role>` to `policy.csv`.
- The OAuth app credentials come from the encrypted secret `argocd-github-oauth` (see [secrets.md](secrets.md)). Dex references them as `$argocd-github-oauth:clientID`, which requires the label `app.kubernetes.io/part-of: argocd` on the secret.
- The OAuth app callback URL is `https://argocd.lab.home.arpa/api/dex/callback`. If the organization restricts third-party OAuth apps, the app has to be approved for it, or Dex cannot read team membership.
- There is no fallback password. If GitHub login breaks, inspect the applications with `kubectl`.

## Checks

```sh
kubectl --kubeconfig ./kubeconfig -n argocd get applications
kubectl --kubeconfig ./kubeconfig -n argocd port-forward svc/argocd-server 8080:80   # bypasses the gateway; GitHub login does not work here
```
