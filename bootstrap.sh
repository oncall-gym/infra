#!/usr/bin/env bash
# Brings the cluster up from scratch: VMs and Talos, then Cilium, then Argo CD.
# Argo CD installs everything else from Git.
set -euo pipefail

CILIUM_VERSION="1.20.2"      # helm search repo cilium/cilium
ARGOCD_VERSION="10.9.6"      # same as in gitops/apps/argocd.yaml
GATEWAY_API_VERSION="v1.6.1" # same as in gitops/apps/gateway-api-crds.yaml
REPO_URL="git@github.com:artem-dev-ops/DevOps-Troubleshoot-Training.git"
DEPLOY_KEY="${DEPLOY_KEY:-$HOME/argocd-deploy-key}"
CA_SECRET="${CA_SECRET:-$HOME/.lab/lab-root-ca-secret.json}"
AGE_KEY="${AGE_KEY:-$HOME/.lab/age.key}"
[ -f "$AGE_KEY" ] || { echo "age key not found: $AGE_KEY" >&2; exit 1; }

# Check all prerequisites before creating anything
for cmd in terraform kubectl helm jq; do
  command -v "$cmd" >/dev/null || { echo "Utility not found: $cmd" >&2; exit 1; }
done
[ -f "$DEPLOY_KEY" ] || { echo "Deploy key not found: $DEPLOY_KEY" >&2; exit 1; }

# The component is already managed by Argo CD: this is a live cluster,
# and it must not be installed with Helm again
managed_by_argocd() {
  kubectl -n argocd get application "$1" >/dev/null 2>&1
}

# Strips the service fields that would prevent the secret from being created again
clean_secret() {
  jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
          .metadata.managedFields, .metadata.ownerReferences,
          .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'
}

terraform apply -parallelism=1
terraform output -raw kubeconfig  > kubeconfig
terraform output -raw talosconfig > talosconfig
export KUBECONFIG="$PWD/kubeconfig"

echo "Waiting for the API server..."
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done

helm repo add cilium https://helm.cilium.io >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

# The Gateway API types are needed before Cilium starts: otherwise it does not enable
# gateway support and has to be restarted by hand. Install them only on a fresh
# cluster: on a live one Argo CD already manages them, and we must not fight it.
if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
else
  echo "Gateway API types already exist, skipping"
fi

# Without a CNI the nodes stay NotReady, so Cilium is installed before everything else
if managed_by_argocd cilium; then
  echo "Cilium is already managed by Argo CD, skipping"
else
  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system --version "$CILIUM_VERSION" \
    -f gitops/cilium/values.yaml
fi

echo "Waiting for the nodes to register..."
until [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 3 ]; do sleep 5; done
kubectl wait --for=condition=Ready nodes --all --timeout=10m

if managed_by_argocd argocd; then
  echo "Argo CD already manages itself, skipping"
else
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace --version "$ARGOCD_VERSION" \
    -f gitops/argocd/values.yaml --wait
fi

kubectl -n argocd create secret generic repo-local-infra \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-file=sshPrivateKey="$DEPLOY_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret repo-local-infra \
  argocd.argoproj.io/secret-type=repository --overwrite

# Lab root certificate: restore it before cert-manager starts,
# so that it does not generate a new one
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
if [ -s "$CA_SECRET" ]; then
  if kubectl -n cert-manager get secret lab-root-ca >/dev/null 2>&1; then
    echo "Root certificate is already in the cluster, skipping"
  else
    kubectl create -f "$CA_SECRET"
    echo "Root certificate restored from $CA_SECRET"
  fi
else
  echo "No saved root certificate, cert-manager will create a new one"
fi

# The key the operator uses to decrypt secrets from Git
kubectl create namespace sops-secrets-operator --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sops-secrets-operator create secret generic sops-age-key-file \
  --from-file=key="$AGE_KEY" --dry-run=client -o yaml | kubectl apply -f -

# From here on Argo CD installs everything else from Git
kubectl apply -f gitops/root.yaml

# On a fresh install, save the new root certificate for future re-creations
if [ ! -s "$CA_SECRET" ]; then
  echo "Waiting for cert-manager to create the root certificate (up to 15 minutes)..."
  for _ in $(seq 90); do
    kubectl -n cert-manager get secret lab-root-ca >/dev/null 2>&1 && break
    sleep 10
  done
  if ! kubectl -n cert-manager get secret lab-root-ca >/dev/null 2>&1; then
    echo "The certificate never appeared. The cluster is up, but save it by hand later." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$CA_SECRET")"
  # Write to a temporary file so that a failure does not leave an empty one behind
  ( umask 077
    kubectl -n cert-manager get secret lab-root-ca -o json | clean_secret > "$CA_SECRET.tmp" )
  mv "$CA_SECRET.tmp" "$CA_SECRET"
  echo "Saved to $CA_SECRET. Copy it into a password manager and add the certificate to the trusted store."
fi

echo "Done."
