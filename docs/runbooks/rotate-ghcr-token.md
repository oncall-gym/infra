# Runbook: rotate the GHCR pull token

| | |
|---|---|
| **Applies to** | Image pulls from `ghcr.io/oncall-gym/*` in cluster `lab` |
| **Use when** | The token is about to expire; the token leaked (see [If the token leaked](#if-the-token-leaked)); GitHub revoked the token automatically (for example, secret scanning found it in a public commit), so pulls fail with `401`; the bot account lost access to the package |
| **Secret** | SopsSecret `gitops/secrets/ghcr-pull.enc.yaml` → `trainer/ghcr-pull` (`kubernetes.io/dockerconfigjson`) |
| **Used by** | `imagePullSecrets` of Deployment `trainer/trainer-api` |
| **Token owner** | Machine account `oncall-gym-bot` (credentials and 2FA in Bitwarden), **Read** access to package `trainer-api` only |
| **Token** | Personal access token (classic), scope `read:packages` only |
| **Current token** | `oncall-gym lab: ghcr pull 2026`, created 2026-10-18, **expires 2027-10-18** |
| **Duration** | ~15 min |

## What breaks when the token expires

Nothing right away. Running pods keep running, and kubelet reuses images already cached on a node. The failure shows up later, as `ImagePullBackOff` with `401 Unauthorized` in the pod events, when:

- a deploy changes the image tag (every trainer release does);
- a pod is rescheduled to a node that does not have the image yet (node reboot, drain, rebuild).

Rotate before the expiry date, not after the first failed deploy.

## Prerequisites

- `jq`, `curl`, `kubectl`, and a `sops` whose `sops set --help` lists `--value-stdin`.
  Run from the repository root (direnv sets `SOPS_AGE_KEY_FILE` and `KUBECONFIG`).
- Push access to `oncall-gym/infra`: the push to `main` is what applies the new secret.
- Access to the `oncall-gym-bot` account. Its mailbox must forward to a human: GitHub sends the expiry reminder (about a week before) there.
- Package `trainer-api` must **not** inherit access from its source repository
  (Package settings → *Inherit access from source repository* off), and the bot must be listed under
  *Manage access* with role **Read**. With inheritance on, the bot could only get access through the private
  `trainer` repository and would see its source code.

## Procedure

Run steps 2–4 in **one shell session**: they share `$IMAGE`, `$TAG` and `$GHCR_USER`.

### 1. Create a new token

Signed in as **`oncall-gym-bot`**, on https://github.com/settings/tokens/new (personal access token, classic):

- **Note:** `oncall-gym lab: ghcr pull <year>`, so the old and new tokens are easy to tell apart;
- **Expiration:** custom, one year ahead;
- **Scopes:** `read:packages` only. No `repo`, no `write:packages`.

Copy the token. Keep the old one active until step 5.

### 2. Check the new token against the registry

Test against the image that is deployed right now: it exists in the registry and it is what the cluster
will pull next. Read the token without echo, so it stays out of the terminal and the shell history.
Credentials are passed to `curl` through stdin (`-K -`), so they never appear in the process list.

```bash
IMAGE=$(kubectl -n trainer get deploy trainer-api -o jsonpath='{.spec.template.spec.containers[0].image}')
TAG=${IMAGE##*:}   # assumes a tag; for an @sha256: reference use ${IMAGE##*@} instead
echo "$IMAGE"

GHCR_USER=oncall-gym-bot
read -rs -p 'New GHCR token: ' GHCR_TOKEN; echo

REG_TOKEN=$(printf 'user = "%s:%s"\n' "$GHCR_USER" "$GHCR_TOKEN" | curl -fsS -K - \
  "https://ghcr.io/token?scope=repository:oncall-gym/trainer-api:pull" | jq -r .token)

# The token endpoint alone is not enough: it can return a registry token without access
# to the package. Fetching the manifest is the real test.
printf 'header = "Authorization: Bearer %s"\n' "$REG_TOKEN" | curl -sS -K - -o /dev/null -w '%{http_code}\n' \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "https://ghcr.io/v2/oncall-gym/trainer-api/manifests/$TAG"
# 200: the token can pull. 401/403/404: wrong scope, or the bot has no access to the package.
unset REG_TOKEN
```

### 3. Put the token into the SopsSecret

`sops set --value-stdin` replaces one value and re-encrypts the file. The plaintext is never written to disk,
shown, or passed as a command-line argument:

```bash
CFG=$(printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' \
  "$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)")

jq -n --arg v "$CFG" '$v' | sops set --value-stdin gitops/secrets/ghcr-pull.enc.yaml \
  '["spec"]["secretTemplates"][0]["stringData"][".dockerconfigjson"]'

unset GHCR_TOKEN CFG
```

Check the result before committing:

```bash
git diff gitops/secrets/ghcr-pull.enc.yaml   # only ENC[...] values and sops metadata change
grep -n 'dockerconfigjson' gitops/secrets/ghcr-pull.enc.yaml   # the value starts with ENC[AES256_GCM
```

### 4. Commit, push and verify in the cluster

```bash
git add gitops/secrets/ghcr-pull.enc.yaml
git commit -m "Rotate the GHCR pull token"
git push
```

Argo CD syncs `platform-secrets` within a few minutes, and the operator updates the Secret:

```bash
kubectl -n argocd get application platform-secrets   # Synced / Healthy
kubectl -n trainer get sopssecret ghcr-pull          # Healthy
```

Restarting `trainer-api` does **not** test the token: the image is already cached on the node,
so kubelet does not contact the registry. Force a real pull with a throwaway pod instead.

This is a deliberate exception to the "no manual changes in the cluster" rule in `AGENTS.md`: the pod is
temporary, Argo CD does not track it, and it is deleted at the end of this step.

The pod must not run a second copy of the API (its session reaper assumes a single instance). Two safeguards:
`SCENARIOS_DIR` points nowhere, so the binary exits before it touches Kubernetes, and no ServiceAccount
token is mounted, so it could not act even if it did.

```bash
kubectl -n trainer run pull-test --restart=Never \
  --image="$IMAGE" --image-pull-policy=Always \
  --overrides="$(jq -n --arg img "$IMAGE" '{
    spec: {
      automountServiceAccountToken: false,
      imagePullSecrets: [{name: "ghcr-pull"}],
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{
        name: "pull-test", image: $img, imagePullPolicy: "Always",
        env: [{name: "SCENARIOS_DIR", value: "/nonexistent"}],
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      }]
    }
  }')"

sleep 20
kubectl -n trainer get events --field-selector involvedObject.name=pull-test | grep -E 'Pulled|Failed'
# expected: "Successfully pulled image"; "401 Unauthorized" means the new secret does not work
kubectl -n trainer delete pod pull-test
```

The pod exits with an error right after the pull; that is expected. Only the pull matters here.

### 5. Revoke the old token

Only after step 4 shows a successful pull: signed in as `oncall-gym-bot`, on
https://github.com/settings/tokens delete the token with the previous year in its note.

### 6. Record the rotation

- Update **Current token** in the table at the top with the new name and dates.
- Set a calendar reminder two weeks before the new expiry date.
- Add a row to the history below. Never record the token value, not even partially.

## If the token leaked

Order changes: revoke first, then rotate.

1. Delete the leaked token immediately (step 5). Running pods are not affected; only new pulls fail until step 4 is done.
2. Do steps 1–4.
3. Assess exposure. GitHub does not show who pulled a package or when: the package page has only an
   aggregate download count. Compare it with the pulls you expect from the cluster; an unexplained jump
   means the image (and the scenarios baked into it) should be treated as copied.
4. Record it in the history with reason `leak` and how it leaked.

## Rotation history

| Date | Token name (GitHub note) | Expires | Reason | Notes |
|---|---|---|---|---|
| 2026-10-18 | `oncall-gym lab: ghcr pull 2026` | 2027-10-18 | Initial token | Created together with the trainer deployment |
