# Secrets

Secrets live in Git encrypted with [SOPS](https://github.com/getsops/sops) and age. [sops-secrets-operator](https://github.com/isindir/sops-secrets-operator) decrypts them in the cluster: each `SopsSecret` object becomes a regular `Secret` with the same name.

## How it works

- `.sops.yaml` encrypts `*.enc.yaml` files for one age public key, and only the fields with the `Templates` suffix, that is `spec.secretTemplates`. The kind, name and namespace stay readable in diffs. The public key is not a secret.
- The application `platform-secrets` applies `gitops/secrets/` as is; Argo CD never sees plaintext.
- The operator reads the age private key from the secret `sops-age-key-file`, which `bootstrap.sh` creates. The key is not in Git, and the same key is reused across cluster rebuilds: if it is lost, the files in `gitops/secrets` cannot be decrypted and every secret has to be created again.

| File | Secret | Contents |
| --- | --- | --- |
| `argocd-github-oauth.enc.yaml` | `argocd/argocd-github-oauth` | GitHub OAuth app credentials for Argo CD login |
| `alertmanager-config.enc.yaml` | `monitoring/alertmanager-config` | the Alertmanager configuration, including SMTP credentials |
| `talos-backup-s3.enc.yaml` | `talos-backup/talos-backup-s3` | upload-only S3 keys for etcd snapshots |
| `ghcr-pull.enc.yaml` | `trainer/ghcr-pull` | GHCR pull token of `oncall-gym-bot` for trainer images, expires 2027-10-18; see [runbooks/rotate-ghcr-token.md](runbooks/rotate-ghcr-token.md) |

## Editing

```sh
export SOPS_AGE_KEY_FILE=~/.lab/age.key

# Edit an existing secret: sops decrypts it in the editor and re-encrypts on save
sops gitops/secrets/alertmanager-config.enc.yaml

# Add a new one: write the SopsSecret in plain text, then encrypt it in place
sops --encrypt --in-place gitops/secrets/<name>.enc.yaml
```

The file name must end with `.enc.yaml`, or the rule in `.sops.yaml` does not apply. Before committing, check that `spec.secretTemplates` holds only `ENC[...]` values.

## Checks

```sh
kubectl --kubeconfig ./kubeconfig get sopssecrets -A   # all must be Healthy
```
