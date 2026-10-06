# local-infra

Локальная инфраструктура для MVP тренажёра траблшутинга для DevOps.

## Назначение

Репозиторий описывает окружение, на котором разворачивается и обкатывается MVP тренажёра: платформа, на которой будут подниматься учебные стенды с заранее заложенными неисправностями для отработки навыков диагностики и устранения проблем.

## Принятые решения

| Область | Решение |
| --- | --- |
| Виртуализация | Proxmox VE 9.2.21 |
| ОС узлов | Talos Linux v1.14.2 |
| Kubernetes | v1.37.0 |
| Имя кластера | `lab` |
| Состав кластера | 1 control plane (master) и 2 worker-узла |
| IP-адреса узлов | Статически прописаны на роутере (см. «Сеть узлов») |
| Провижининг | Terraform: провайдеры `bpg/proxmox` (ВМ) и `siderolabs/talos` (конфигурация и bootstrap Talos) |
| Доставка приложений | Argo CD v3.5.3 (GitOps, схема app of apps), манифесты — в каталоге `gitops/` |
| Балансировка (сервисы `LoadBalancer`) | MetalLB v0.16.1, режим L2, пул адресов 192.168.91.220–192.168.91.230 |

## Сеть узлов

IP-адреса хостов Talos статически прописаны на роутере:

| Узел | Роль | IP-адрес | Имя узла в кластере | Ключ в Terraform | VMID |
| --- | --- | --- | --- | --- | --- |
| master | control plane | 192.168.91.201 | `talos-cp1` | `cp1` | 201 |
| worker 1 | worker | 192.168.91.211 | `talos-w1` | `w1` | 211 |
| worker 2 | worker | 192.168.91.212 | `talos-w2` | `w2` | 212 |

MAC-адреса ВМ заданы в Terraform явно, чтобы совпадать с арендами на роутере.

Диапазон 192.168.91.220–192.168.91.230 в той же подсети отдан MetalLB под адреса сервисов типа `LoadBalancer` (см. «Балансировка (MetalLB)»).

## Кластер

Кластер Talos `lab` развёрнут через Terraform (см. «Провижининг»). Все три узла в состоянии `Ready`.

| Параметр | Значение |
| --- | --- |
| Talos API (endpoint) | 192.168.91.201 |
| Kubernetes API | https://192.168.91.201:6443 |
| Контекст `talosctl` | `lab` |
| Контекст `kubectl` | `admin@lab` |

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig get nodes -o wide
talosctl --talosconfig ./talosconfig -n 192.168.91.201 version
```

## Провижининг

ВМ в Proxmox и кластер Talos описаны в Terraform-конфигурации в корне репозитория. Один `terraform apply` создаёт ВМ, применяет machine config, выполняет bootstrap и получает kubeconfig.

| Компонент | Версия |
| --- | --- |
| Terraform | v1.16.5 (требуется >= 1.6) |
| Провайдер `bpg/proxmox` | 0.115.0 |
| Провайдер `siderolabs/talos` | 0.12.0 |

Файлы:

| Файл | Назначение | В VCS |
| --- | --- | --- |
| `main.tf` | провайдеры, ВМ, секреты и конфигурация Talos, bootstrap | да |
| `variables.tf` | переменные (адрес Proxmox, хранилище, ISO, версия Talos, описание нод) | да |
| `outputs.tf` | выходы `kubeconfig` и `talosconfig` (sensitive) | да |
| `.terraform.lock.hcl` | зафиксированные версии провайдеров | да |
| `terraform.tfvars` | installer image и параметры нод (VMID, IP, MAC, CPU, RAM) | нет |
| `terraform.tfstate`, `terraform.tfstate.backup` | state; содержит секреты кластера | нет |
| `kubeconfig`, `talosconfig` | клиентские конфиги, выгруженные из выходов Terraform | нет |

Особенности конфигурации:

- ВМ загружаются по UEFI (OVMF), диск — `scsi0` на `local-lvm` (20 ГБ), ISO Talos (`local:iso/talos.iso`) подключён как `ide3`.
- Установка на диск описана документом `UnattendedInstallConfig` (Talos 1.14), образ установщика берётся с `factory.talos.dev` и задаётся переменной `talos_installer_image`.
- Имена узлов задаются документом `HostnameConfig`: `talos-<ключ ноды>`.
- Секреты кластера (`talos_machine_secrets`) и сгенерированные machine config хранятся только в state; отдельных файлов `controlplane.yaml` и `worker.yaml` больше нет.
- State локальный, лежит в корне репозитория.

Использование:

```sh
export TF_VAR_proxmox_api_token='terraform@pve!tf=<uuid>'

terraform init
terraform plan
terraform apply

terraform output -raw kubeconfig > kubeconfig
terraform output -raw talosconfig > talosconfig
```

Токен API Proxmox передаётся только через переменную окружения `TF_VAR_proxmox_api_token` и в файлы не записывается.

## Доставка приложений (GitOps)

В кластере установлен Argo CD, который синхронизирует состояние кластера с каталогом `gitops/` этого репозитория (ветка `main`).

| Параметр | Значение |
| --- | --- |
| Argo CD | v3.5.3 |
| Helm-чарт | `argo-cd` 10.9.6 из `https://argoproj.github.io/argo-helm` |
| Namespace | `argocd` |
| Имя релиза | `argocd` |
| Репозиторий | `git@github.com:artem-dev-ops/DevOps-Troubleshoot-Training.git` (SSH) |
| Проект Argo CD | `default` |

Структура:

| Путь | Назначение |
| --- | --- |
| `gitops/root.yaml` | корневое приложение `root`: следит за каталогом `gitops/apps` |
| `gitops/apps/` | манифесты `Application`, по одному на компонент |
| `gitops/apps/argocd.yaml` | приложение `argocd`: Argo CD управляет собственным Helm-релизом |
| `gitops/argocd/values.yaml` | значения чарта Argo CD |
| `gitops/apps/metallb.yaml` | приложение `metallb`: Helm-чарт MetalLB |
| `gitops/apps/metallb-config.yaml` | приложение `metallb-config`: следит за каталогом `gitops/metallb-config` |
| `gitops/metallb-config/pool.yaml` | пул адресов и L2-анонс MetalLB |

Как это работает:

- Приложение `root` применяет всё, что лежит в `gitops/apps`. Чтобы добавить компонент в кластер, достаточно положить туда манифест `Application` и отправить коммит в `main`.
- У всех приложений включена автоматическая синхронизация с `prune` и `selfHeal`: ручные правки в кластере откатываются, а удалённое из Git удаляется из кластера.
- Для экономии памяти в чарте отключены Dex (SSO) и контроллер уведомлений.
- Доступ к репозиторию — по SSH-ключу из секрета `repo-local-infra` в namespace `argocd`. Секрет создан вручную и в Git не хранится.

Первичная установка (выполняется один раз на новом кластере, дальше Argo CD обслуживает себя сам):

```sh
helm --kubeconfig ./kubeconfig repo add argo https://argoproj.github.io/argo-helm
helm --kubeconfig ./kubeconfig install argocd argo/argo-cd --version 10.9.6 \
  --namespace argocd --create-namespace -f gitops/argocd/values.yaml

kubectl --kubeconfig ./kubeconfig -n argocd create secret generic repo-local-infra \
  --from-literal=type=git \
  --from-literal=url=git@github.com:artem-dev-ops/DevOps-Troubleshoot-Training.git \
  --from-file=sshPrivateKey=<путь к приватному ключу>
kubectl --kubeconfig ./kubeconfig -n argocd label secret repo-local-infra \
  argocd.argoproj.io/secret-type=repository

kubectl --kubeconfig ./kubeconfig apply -f gitops/root.yaml
```

Проверка состояния и доступ к интерфейсу (ingress пока нет, сервис `argocd-server` — `ClusterIP`):

```sh
kubectl --kubeconfig ./kubeconfig -n argocd get applications
kubectl --kubeconfig ./kubeconfig -n argocd port-forward svc/argocd-server 8080:443
```

## Балансировка (MetalLB)

Сервисы типа `LoadBalancer` получают внешние адреса от MetalLB. Он установлен через Argo CD двумя приложениями: `metallb` ставит сам MetalLB, `metallb-config` — его настройки.

| Параметр | Значение |
| --- | --- |
| MetalLB | v0.16.1 |
| Helm-чарт | `metallb` 0.16.1 из `https://metallb.github.io/metallb` |
| Namespace | `metallb-system` |
| Режим | L2 (ARP) |
| Пул адресов | `lan`: 192.168.91.220–192.168.91.230, автоназначение включено |
| Анонс | `L2Advertisement` `lan` для пула `lan` |

Особенности:

- Значения чарта не переопределяются, используется конфигурация по умолчанию.
- Namespace `metallb-system` создаёт Argo CD (`CreateNamespace=true`) с меткой `pod-security.kubernetes.io/enforce: privileged`: speaker работает в сети хоста, а Talos по умолчанию применяет профиль `baseline`.
- `IPAddressPool` и `L2Advertisement` вынесены в отдельное приложение, потому что их CRD появляются только после установки чарта. Поэтому у `metallb-config` включены `SkipDryRunOnMissingResource=true` и повторные попытки синхронизации.
- Адреса пула не должны пересекаться с DHCP-диапазоном роутера и адресами узлов.

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig -n metallb-system get pods
kubectl --kubeconfig ./kubeconfig -n metallb-system get ipaddresspools,l2advertisements
kubectl --kubeconfig ./kubeconfig get svc -A | grep LoadBalancer
```

## Ресурсы

Доступный бюджет ресурсов на Proxmox:

| Ресурс | Объём |
| --- | --- |
| vCPU | 12 |
| RAM | 16 ГБ |

Все виртуальные машины MVP должны укладываться в этот бюджет.

Текущее распределение (задано в `terraform.tfvars`):

| Узел | vCPU | RAM | Диск |
| --- | --- | --- | --- |
| `talos-cp1` | 2 | 4 ГБ | 20 ГБ |
| `talos-w1` | 4 | 5 ГБ | 20 ГБ |
| `talos-w2` | 4 | 5 ГБ | 20 ГБ |
| **Итого** | **10** | **14 ГБ** | **60 ГБ** |

Остаток — 2 vCPU и 2 ГБ RAM — на накладные расходы Proxmox.

## Открытые вопросы

Будут решены позже:

- окончательное распределение ресурсов между ВМ (текущее — в разделе «Ресурсы»);
- сеть (CNI, ingress);
- хранилище;
- наблюдаемость (метрики, логи);
- механизм запуска и сброса сценариев тренажёра.

## Статус

Кластер Talos `lab` (1 control plane и 2 worker-узла) развёрнут через Terraform и работает. В кластере установлены Argo CD и MetalLB, приложения `root`, `argocd`, `metallb` и `metallb-config` — `Synced` и `Healthy`. Сервисов типа `LoadBalancer` пока нет. Прикладные компоненты и остальные открытые вопросы — впереди.

## Журнал изменений

- 2026-10-03 — Proxmox VE обновлён до версии 9.2.21.
- 2026-10-03 — зафиксированы статические IP-адреса узлов Talos на роутере: master — 192.168.91.201, worker-узлы — 192.168.91.211 и 192.168.91.212.
- 2026-10-03 — вручную поднят кластер Talos `lab`: Talos v1.14.2, Kubernetes v1.37.1, все три узла `Ready`.
- 2026-10-05 — кластер `lab` пересоздан через Terraform (провайдеры `bpg/proxmox` и `siderolabs/talos`): Talos v1.14.2, Kubernetes v1.37.0, узлы `talos-cp1`, `talos-w1`, `talos-w2`. Провижининг перенесён из открытых вопросов в принятые решения.
- 2026-10-05 — в кластер установлен Argo CD v3.5.3 (чарт `argo-cd` 10.9.6), создано корневое приложение `root` по схеме app of apps. Доставка приложений перенесена из открытых вопросов в принятые решения.
- 2026-10-06 — через Argo CD установлен MetalLB v0.16.1 (чарт `metallb` 0.16.1) в режиме L2 с пулом адресов 192.168.91.220–192.168.91.230. Балансировка перенесена из открытых вопросов в принятые решения.
