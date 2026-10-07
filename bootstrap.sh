#!/usr/bin/env bash
# Поднимает кластер с нуля: ВМ и Talos, затем Cilium, затем Argo CD.
# Всё остальное Argo CD ставит сам из Git.
set -euo pipefail

CILIUM_VERSION="1.20.2"   # helm search repo cilium/cilium
ARGOCD_VERSION="10.9.6"   # та же, что в gitops/apps/argocd.yaml
REPO_URL="git@github.com:artem-dev-ops/DevOps-Troubleshoot-Training.git"         # git@github.com:<логин>/<репозиторий>.git
DEPLOY_KEY="${DEPLOY_KEY:-$HOME/argocd-deploy-key}"

terraform apply -parallelism=1
terraform output -raw kubeconfig  > kubeconfig
terraform output -raw talosconfig > talosconfig
export KUBECONFIG="$PWD/kubeconfig"

echo "Жду API-сервер..."
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done

helm repo add cilium https://helm.cilium.io >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

# Без CNI ноды остаются NotReady, поэтому Cilium ставится первым
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system --version "$CILIUM_VERSION" \
  -f gitops/cilium/values.yaml

echo "Жду регистрации нод..."
until [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 3 ]; do sleep 5; done
kubectl wait --for=condition=Ready nodes --all --timeout=10m

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --version "$ARGOCD_VERSION" \
  -f gitops/argocd/values.yaml --wait

kubectl -n argocd create secret generic repo-local-infra \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-file=sshPrivateKey="$DEPLOY_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret repo-local-infra \
  argocd.argoproj.io/secret-type=repository --overwrite

kubectl apply -f gitops/root.yaml
echo "Готово. Остальное Argo CD поставит из Git."
