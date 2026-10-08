#!/usr/bin/env bash
# Поднимает кластер с нуля: ВМ и Talos, затем Cilium, затем Argo CD.
# Всё остальное Argo CD ставит сам из Git.
set -euo pipefail

CILIUM_VERSION="1.20.2"      # helm search repo cilium/cilium
ARGOCD_VERSION="10.9.6"      # та же, что в gitops/apps/argocd.yaml
GATEWAY_API_VERSION="v1.6.1" # та же, что в gitops/apps/gateway-api-crds.yaml
REPO_URL="git@github.com:artem-dev-ops/DevOps-Troubleshoot-Training.git"
DEPLOY_KEY="${DEPLOY_KEY:-$HOME/argocd-deploy-key}"
CA_SECRET="${CA_SECRET:-$HOME/.lab/lab-root-ca-secret.json}"

# Проверяем всё необходимое до того, как что-то создавать
for cmd in terraform kubectl helm jq; do
  command -v "$cmd" >/dev/null || { echo "Не найдена утилита: $cmd" >&2; exit 1; }
done
[ -f "$DEPLOY_KEY" ] || { echo "Не найден deploy-ключ: $DEPLOY_KEY" >&2; exit 1; }

# Компонент уже передан под управление Argo CD: значит, это живой кластер,
# и ставить его через Helm повторно нельзя
managed_by_argocd() {
  kubectl -n argocd get application "$1" >/dev/null 2>&1
}

# Убирает из секрета служебные поля, с которыми его нельзя создать заново
clean_secret() {
  jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
          .metadata.managedFields, .metadata.ownerReferences,
          .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'
}

terraform apply -parallelism=1
terraform output -raw kubeconfig  > kubeconfig
terraform output -raw talosconfig > talosconfig
export KUBECONFIG="$PWD/kubeconfig"

echo "Жду API-сервер..."
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done

helm repo add cilium https://helm.cilium.io >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

# Типы Gateway API нужны до старта Cilium: иначе он не включит поддержку
# шлюзов, и придётся перезапускать его вручную. Ставим их только на свежий
# кластер: на живом ими уже управляет Argo CD, и спорить с ним не нужно.
if ! kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
else
  echo "Типы Gateway API уже есть, пропускаю"
fi

# Без CNI ноды остаются NotReady, поэтому Cilium ставится раньше всего остального
if managed_by_argocd cilium; then
  echo "Cilium уже под управлением Argo CD, пропускаю"
else
  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system --version "$CILIUM_VERSION" \
    -f gitops/cilium/values.yaml
fi

echo "Жду регистрации нод..."
until [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 3 ]; do sleep 5; done
kubectl wait --for=condition=Ready nodes --all --timeout=10m

if managed_by_argocd argocd; then
  echo "Argo CD уже управляет сам собой, пропускаю"
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

# Корневой сертификат стенда: восстанавливаем до запуска cert-manager,
# чтобы он не сгенерировал новый
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
if [ -s "$CA_SECRET" ]; then
  if kubectl -n cert-manager get secret lab-root-ca >/dev/null 2>&1; then
    echo "Корневой сертификат уже в кластере, пропускаю"
  else
    kubectl create -f "$CA_SECRET"
    echo "Корневой сертификат восстановлен из $CA_SECRET"
  fi
else
  echo "Сохранённого корневого сертификата нет, cert-manager создаст новый"
fi

# С этого момента Argo CD ставит всё остальное из Git
kubectl apply -f gitops/root.yaml

# На свежей установке сохраняем новый корневой сертификат для следующих пересозданий
if [ ! -s "$CA_SECRET" ]; then
  echo "Жду, пока cert-manager создаст корневой сертификат (до 15 минут)..."
  for _ in $(seq 90); do
    kubectl -n cert-manager get secret lab-root-ca >/dev/null 2>&1 && break
    sleep 10
  done
  if ! kubectl -n cert-manager get secret lab-root-ca >/dev/null 2>&1; then
    echo "Сертификат так и не появился. Кластер поднят, но сохрани его позже вручную." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$CA_SECRET")"
  # Пишем во временный файл, чтобы при ошибке не остался пустой
  ( umask 077
    kubectl -n cert-manager get secret lab-root-ca -o json | clean_secret > "$CA_SECRET.tmp" )
  mv "$CA_SECRET.tmp" "$CA_SECRET"
  echo "Сохранён в $CA_SECRET. Скопируй его в менеджер паролей и добавь сертификат в доверенные."
fi

echo "Готово."
