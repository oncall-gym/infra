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
| Развёртывание с нуля | Скрипт `bootstrap.sh`: Terraform, затем CRD Gateway API и Cilium, затем Argo CD |
| Сеть кластера (CNI) | Cilium v1.20.2 вместо встроенных Flannel и kube-proxy, с Hubble (relay и UI) |
| Доставка приложений | Argo CD v3.5.3 (GitOps, схема app of apps), манифесты — в каталоге `gitops/` |
| Балансировка (сервисы `LoadBalancer`) | MetalLB v0.16.1, режим L2, пул адресов 192.168.91.220–192.168.91.230 |
| Входящий трафик (ingress) | Gateway API v1.6.1 в реализации Cilium: общий шлюз `lab` на 192.168.91.220, HTTPS (HTTP перенаправляется на HTTPS), имена `*.lab.home.arpa` |
| TLS и сертификаты | cert-manager v1.21.2 с собственным центром сертификации стенда (`ClusterIssuer` `lab-ca`); TLS завершается на шлюзе, сертификат — `*.lab.home.arpa` |

## Сеть узлов

IP-адреса хостов Talos статически прописаны на роутере:

| Узел | Роль | IP-адрес | Имя узла в кластере | Ключ в Terraform | VMID |
| --- | --- | --- | --- | --- | --- |
| master | control plane | 192.168.91.201 | `talos-cp1` | `cp1` | 201 |
| worker 1 | worker | 192.168.91.211 | `talos-w1` | `w1` | 211 |
| worker 2 | worker | 192.168.91.212 | `talos-w2` | `w2` | 212 |

MAC-адреса ВМ заданы в Terraform явно, чтобы совпадать с арендами на роутере.

Диапазон 192.168.91.220–192.168.91.230 в той же подсети отдан MetalLB под адреса сервисов типа `LoadBalancer` (см. «Балансировка (MetalLB)»). Первый адрес диапазона, 192.168.91.220, закреплён за шлюзом `lab` (см. «Входящий трафик (Gateway API)»).

## Кластер

Кластер Talos `lab` развёрнут скриптом `bootstrap.sh` (см. «Развёртывание с нуля»), ВМ и конфигурация Talos описаны в Terraform (см. «Провижининг»). Все три узла в состоянии `Ready`.

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

ВМ в Proxmox и кластер Talos описаны в Terraform-конфигурации в корне репозитория. Один `terraform apply` создаёт ВМ, применяет machine config, выполняет bootstrap и получает kubeconfig. Узлы после этого остаются `NotReady`, пока не установлен CNI, поэтому с нуля кластер поднимается скриптом `bootstrap.sh` (см. «Развёртывание с нуля»).

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
| `bootstrap.sh` | развёртывание кластера с нуля (см. «Развёртывание с нуля») | да |

Особенности конфигурации:

- ВМ загружаются по UEFI (OVMF), диск — `scsi0` на `local-lvm` (20 ГБ), ISO Talos (`local:iso/talos.iso`) подключён как `ide3`.
- Установка на диск описана документом `UnattendedInstallConfig` (Talos 1.14), образ установщика берётся с `factory.talos.dev` и задаётся переменной `talos_installer_image`.
- Имена узлов задаются документом `HostnameConfig`: `talos-<ключ ноды>`.
- У ВМ включено устройство QEMU guest agent (таймаут ожидания — 2 минуты). В образе Talos есть расширение `qemu-guest-agent`: без устройства агента его служба не стартует, и узел навсегда остаётся в стадии `Booting`.
- Встроенные Flannel и kube-proxy отключены под Cilium: в machine config control plane добавлены удаление документа `KubeFlannelCNIConfig` и `KubeProxyConfig` с `enabled: false`. Это настройки кластера, поэтому в конфигурацию worker-узлов они не попадают.
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

## Развёртывание с нуля

Скрипт `bootstrap.sh` поднимает кластер целиком одной командой. Всё, что не входит в его шаги, Argo CD ставит сам из Git.

Шаги скрипта:

1. `terraform apply -parallelism=1` — ВМ и кластер Talos. Terraform запрашивает подтверждение как обычно.
2. Выгрузка `kubeconfig` и `talosconfig` из выходов Terraform в корень репозитория.
3. Ожидание готовности API-сервера.
4. Установка типов ресурсов (CRD) Gateway API v1.6.1: `kubectl apply --server-side` файла `standard-install.yaml` из релиза `kubernetes-sigs/gateway-api`. Они нужны до Cilium: оператор создаёт `GatewayClass` `cilium`, только если CRD уже есть на момент его запуска.
5. Установка Cilium через Helm в `kube-system` со значениями из `gitops/cilium/values.yaml`. Без CNI узлы остаются `NotReady`, поэтому Cilium ставится раньше остальных компонентов.
6. Ожидание регистрации трёх узлов и их состояния `Ready`.
7. Установка Argo CD через Helm в `argocd` со значениями из `gitops/argocd/values.yaml`.
8. Создание секрета `repo-local-infra` с SSH-ключом доступа к репозиторию.
9. Применение корневого приложения `gitops/root.yaml`.

Что нужно до запуска:

- установленные `terraform`, `kubectl` и `helm`, выполненный `terraform init`;
- заполненный `terraform.tfvars` и переменная окружения `TF_VAR_proxmox_api_token`;
- ISO Talos в хранилище Proxmox (`local:iso/talos.iso`);
- доступ к `github.com` с машины, где запускается скрипт (оттуда скачивается манифест CRD Gateway API);
- приватный SSH-ключ доступа Argo CD к репозиторию. Путь задаётся переменной окружения `DEPLOY_KEY`, по умолчанию — `~/argocd-deploy-key`.

Запуск:

```sh
export TF_VAR_proxmox_api_token='terraform@pve!tf=<uuid>'

./bootstrap.sh
```

Особенности:

- Скрипт можно запускать повторно: Helm-релизы ставятся через `helm upgrade --install`, секрет и корневое приложение — через `kubectl apply`.
- Версии чартов заданы в двух местах и должны совпадать: `CILIUM_VERSION` — с `targetRevision` в `gitops/apps/cilium.yaml`, `ARGOCD_VERSION` — с `targetRevision` в `gitops/apps/argocd.yaml`. Иначе Argo CD после установки сразу приведёт релиз к версии из Git.
- Версия Gateway API тоже задана дважды: в адресе манифеста в `bootstrap.sh` и в `targetRevision` приложения `gitops/apps/gateway-api-crds.yaml`. Обе должны совпадать и соответствовать версии, под которую собран Cilium.
- После шага 9 Argo CD берёт под своё управление установленные скриптом релизы `cilium` и `argocd` и типы ресурсов Gateway API (приложение `gateway-api-crds`).
- cert-manager и центр сертификации стенда скрипт не ставит: их разворачивает Argo CD. В новом кластере корневой сертификат выпускается заново, поэтому доверие к нему на клиентских машинах нужно настраивать повторно (см. «Сертификаты (cert-manager)»).

## Сеть кластера (Cilium)

CNI кластера — Cilium. Он заменяет встроенные в Talos Flannel и kube-proxy (оба отключены в machine config, см. «Провижининг»). Первую установку выполняет `bootstrap.sh`, дальше релизом управляет приложение Argo CD `cilium`.

| Параметр | Значение |
| --- | --- |
| Cilium | v1.20.2 |
| Helm-чарт | `cilium` 1.20.2 из `https://helm.cilium.io` |
| Namespace | `kube-system` |
| Имя релиза | `cilium` |
| IPAM | `kubernetes` (подсеть подов — 10.244.0.0/16, по умолчанию в Talos) |
| Замена kube-proxy | включена (`kubeProxyReplacement: true`) |
| Hubble | включены relay и UI |
| Gateway API | включён (`gatewayAPI.enabled: true`), `GatewayClass` `cilium` |

Особенности (значения — в `gitops/cilium/values.yaml`, по документации Talos 1.14):

- К API-серверу Cilium обращается через KubePrism — локальный балансировщик Talos на `localhost:7445`.
- Набор capabilities агента задан явно, автомонтирование cgroup отключено, используется `/sys/fs/cgroup` хоста.
- Для экономии памяти оператор Cilium работает в одной реплике.
- Адреса сервисам типа `LoadBalancer` по-прежнему выдаёт MetalLB.
- Cilium реализует Gateway API: принимает входящий HTTP- и HTTPS-трафик через шлюз `lab` (см. «Входящий трафик (Gateway API)»). Для этого CRD Gateway API должны быть установлены до запуска оператора Cilium.

Hubble UI доступен из локальной сети по адресу https://hubble.lab.home.arpa (сервис `hubble-ui` остаётся `ClusterIP`, наружу его публикует шлюз).

Проверка состояния и запасной доступ к Hubble UI в обход шлюза:

```sh
kubectl --kubeconfig ./kubeconfig -n kube-system get pods -l app.kubernetes.io/part-of=cilium
kubectl --kubeconfig ./kubeconfig -n kube-system port-forward svc/hubble-ui 12000:80
```

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
| `gitops/apps/cilium.yaml` | приложение `cilium`: Helm-чарт Cilium |
| `gitops/cilium/values.yaml` | значения чарта Cilium (их же использует `bootstrap.sh`) |
| `gitops/apps/metallb.yaml` | приложение `metallb`: Helm-чарт MetalLB |
| `gitops/apps/metallb-config.yaml` | приложение `metallb-config`: следит за каталогом `gitops/metallb-config` |
| `gitops/metallb-config/pool.yaml` | пул адресов и L2-анонс MetalLB |
| `gitops/apps/gateway-api-crds.yaml` | приложение `gateway-api-crds`: типы ресурсов (CRD) Gateway API из `kubernetes-sigs/gateway-api` |
| `gitops/apps/gateway.yaml` | приложение `gateway`: следит за каталогом `gitops/gateway` |
| `gitops/gateway/gateway.yaml` | шлюз `lab` |
| `gitops/gateway/routes.yaml` | маршруты `HTTPRoute` к сервисам и перенаправление с HTTP на HTTPS |
| `gitops/apps/cert-manager.yaml` | приложение `cert-manager`: Helm-чарт cert-manager (значения — в самом манифесте) |
| `gitops/apps/cert-manager-config.yaml` | приложение `cert-manager-config`: следит за каталогом `gitops/cert-manager` |
| `gitops/cert-manager/issuers.yaml` | центр сертификации стенда: издатели `ClusterIssuer` и корневой сертификат |

Как это работает:

- Приложение `root` применяет всё, что лежит в `gitops/apps`. Чтобы добавить компонент в кластер, достаточно положить туда манифест `Application` и отправить коммит в `main`.
- У всех приложений включена автоматическая синхронизация с `prune` и `selfHeal`: ручные правки в кластере откатываются, а удалённое из Git удаляется из кластера. Исключение — `gateway-api-crds`: у него `prune` отключён, чтобы типы ресурсов не удалялись автоматически.
- Для экономии памяти в чарте отключены Dex (SSO) и контроллер уведомлений.
- `argocd-server` работает без TLS (`configs.params.server.insecure: true`): TLS завершается на шлюзе, а в сервис шлюз ходит по HTTP.
- Доступ к репозиторию — по SSH-ключу из секрета `repo-local-infra` в namespace `argocd`. Секрет создаёт `bootstrap.sh`, в Git он не хранится.

Первичную установку Argo CD, создание секрета `repo-local-infra` и применение `gitops/root.yaml` выполняет `bootstrap.sh` (см. «Развёртывание с нуля»). Дальше Argo CD обслуживает себя сам.

Интерфейс Argo CD доступен из локальной сети по адресу https://argocd.lab.home.arpa (сервис `argocd-server` остаётся `ClusterIP`, наружу его публикует шлюз, см. «Входящий трафик (Gateway API)»).

Проверка состояния и запасной доступ к интерфейсу в обход шлюза (по HTTP: `argocd-server` работает без TLS):

```sh
kubectl --kubeconfig ./kubeconfig -n argocd get applications
kubectl --kubeconfig ./kubeconfig -n argocd port-forward svc/argocd-server 8080:80
```

## Входящий трафик (Gateway API)

Трафик снаружи принимает один общий шлюз `lab`, реализованный Cilium (Gateway API). Сервисы доступны по HTTPS, запросы по HTTP перенаправляются на HTTPS. Отдельного ingress-контроллера в кластере нет.

| Параметр | Значение |
| --- | --- |
| Gateway API (CRD) | v1.6.1, канал `standard` (под эту версию собран Cilium 1.20) |
| Реализация | Cilium, `GatewayClass` `cilium` (контроллер `io.cilium/gateway-controller`) |
| Шлюз | `Gateway` `lab` в namespace `gateway` |
| Адрес | 192.168.91.220 — сервис `cilium-gateway-lab` типа `LoadBalancer` (порты 80 и 443), адрес выдаёт MetalLB |
| Listener `http` | HTTP, порт 80, имена `*.lab.home.arpa`, маршруты только из namespace `gateway` — здесь живёт одно перенаправление на HTTPS |
| Listener `https` | HTTPS, порт 443, имена `*.lab.home.arpa`, маршруты разрешены из любых namespace |
| TLS | завершается на шлюзе (`mode: Terminate`), сертификат — секрет `lab-wildcard-tls` в namespace `gateway`, выпускает cert-manager (см. «Сертификаты (cert-manager)») |

Опубликованные сервисы:

| Адрес | `HTTPRoute` | Сервис |
| --- | --- | --- |
| https://argocd.lab.home.arpa | `argocd` в namespace `argocd` | `argocd-server:80` |
| https://hubble.lab.home.arpa | `hubble` в namespace `kube-system` | `hubble-ui:80` |

Как это устроено:

- Типы ресурсов Gateway API ставит приложение `gateway-api-crds` из репозитория `kubernetes-sigs/gateway-api` (тег `v1.6.1`, каталог `config/crd`). У него отключён `prune` и включён `ServerSideApply=true`: описания слишком большие для обычного `apply`.
- При развёртывании с нуля те же типы ставит `bootstrap.sh` перед Cilium: оператор Cilium создаёт `GatewayClass` `cilium`, только если CRD уже есть на момент его запуска.
- В значениях чарта Cilium включено `gatewayAPI.enabled` (а также `enableAlpn` и `enableAppProtocol`).
- Приложение `gateway` применяет каталог `gitops/gateway`: `gateway.yaml` (шлюз) и `routes.yaml` (все маршруты). Namespace `gateway` создаёт Argo CD (`CreateNamespace=true`); включены `SkipDryRunOnMissingResource=true` и повторные попытки синхронизации — на случай, когда CRD ещё не установлены.
- Адрес шлюза закреплён аннотацией `metallb.io/loadBalancerIPs: 192.168.91.220` (`spec.infrastructure.annotations` в `Gateway`): Cilium переносит её на создаваемый сервис.
- Сертификат шлюза заказывается аннотацией `cert-manager.io/cluster-issuer: lab-ca` на самом `Gateway`: cert-manager по listener `https` сам создаёт `Certificate` `lab-wildcard-tls` на имя `*.lab.home.arpa` и продлевает его. Отдельного манифеста `Certificate` в Git нет.
- `HTTPRoute` `http-to-https` в namespace `gateway` привязан к listener `http` и отвечает на любой запрос перенаправлением 301 на HTTPS. Других маршрутов на порту 80 нет: listener принимает маршруты только из своего namespace.
- Маршруты к сервисам привязаны к listener `https` (`sectionName: https` в `parentRefs`). Они лежат в `gitops/gateway/routes.yaml`, но создаются в namespace своих сервисов (`argocd`, `kube-system`), поэтому `ReferenceGrant` не нужен.
- TLS завершается на шлюзе, в сервисы он ходит по HTTP, поэтому `argocd-server` запущен с `server.insecure: true` (`gitops/argocd/values.yaml`).
- Имена `*.lab.home.arpa` действуют только в локальной сети и должны разрешаться в 192.168.91.220. DNS-записи настраиваются вне репозитория.

Чтобы опубликовать ещё один сервис, добавь `HTTPRoute` в `gitops/gateway/routes.yaml` (в namespace сервиса, с `parentRefs` на шлюз `lab` в namespace `gateway` и `sectionName: https`) и DNS-запись для нового имени. Новый сертификат не нужен: имя вида `<сервис>.lab.home.arpa` покрывает общий сертификат шлюза.

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig get gatewayclass
kubectl --kubeconfig ./kubeconfig get gateway,httproute -A
curl -I --resolve argocd.lab.home.arpa:80:192.168.91.220 http://argocd.lab.home.arpa/
curl -I --cacert ./lab-root-ca.crt --resolve argocd.lab.home.arpa:443:192.168.91.220 https://argocd.lab.home.arpa/
```

Первый запрос должен вернуть 301 на `https://`, второй — 200.

## Сертификаты (cert-manager)

TLS-сертификаты выпускает cert-manager от имени собственного центра сертификации стенда. Он установлен через Argo CD двумя приложениями: `cert-manager` ставит сам cert-manager, `cert-manager-config` — издателей и корневой сертификат.

| Параметр | Значение |
| --- | --- |
| cert-manager | v1.21.2 |
| Helm-чарт | `cert-manager` v1.21.2 из `https://charts.jetstack.io` |
| Namespace | `cert-manager` |
| Имя релиза | `cert-manager` |
| Рабочий издатель | `ClusterIssuer` `lab-ca` — подписывает сертификаты корневым |
| Корневой сертификат | `Certificate` `lab-root-ca` (`CN=Lab Root CA`, ECDSA P-256, 10 лет), секрет `lab-root-ca` в namespace `cert-manager` |
| Сертификат шлюза | `Certificate` `lab-wildcard-tls` в namespace `gateway`: `*.lab.home.arpa`, 90 дней, продлевается автоматически |

Центр сертификации собран в три шага (`gitops/cert-manager/issuers.yaml`):

1. `ClusterIssuer` `selfsigned-bootstrap` — издатель, который умеет только подписывать сам себя.
2. `Certificate` `lab-root-ca` — корневой сертификат, выпущенный этим издателем.
3. `ClusterIssuer` `lab-ca` — рабочий издатель, который подписывает всё остальное корневым сертификатом.

Особенности:

- Значения чарта заданы прямо в `gitops/apps/cert-manager.yaml` (`valuesObject`): CRD ставит сам чарт (`crds.enabled: true`), в конфигурации контроллера включено `enableGatewayAPI: true` — без этого cert-manager не смотрит на объекты `Gateway`.
- Namespace `cert-manager` создаёт Argo CD (`CreateNamespace=true`).
- Издатели и корневой сертификат вынесены в отдельное приложение, потому что их CRD появляются только после установки чарта. Поэтому у `cert-manager-config` включены `SkipDryRunOnMissingResource=true` и повторные попытки синхронизации.
- Центр сертификации внутренний: публичного доверия к нему нет, а ACME (Let's Encrypt) не используется — имена `*.lab.home.arpa` существуют только в локальной сети.
- Приватный ключ корневого сертификата лежит в секрете `lab-root-ca` в кластере и в его локальной выгрузке `lab-root-ca-secret.yaml`; в Git его нет.

Доверие на клиентских машинах:

- Браузеры и `curl` не доверяют сертификатам стенда, пока корневой сертификат не добавлен в доверенные на клиентской машине.
- Корневой сертификат (без ключа) выгружается так:

  ```sh
  kubectl --kubeconfig ./kubeconfig -n cert-manager get secret lab-root-ca \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
  ```

- При пересоздании кластера корневой сертификат выпускается заново с новым ключом: старый `lab-root-ca.crt` перестаёт подходить, доверие нужно настроить повторно.

Локальные файлы в корне репозитория (сейчас не в VCS):

| Файл | Содержимое | Секрет |
| --- | --- | --- |
| `lab-root-ca.crt` | корневой сертификат стенда — его добавляют в доверенные на клиентских машинах | нет, но в `.gitignore` не внесён |
| `lab-root-ca-secret.yaml` | выгрузка секрета `lab-root-ca` целиком, вместе с приватным ключом центра сертификации | да, добавлен в `.gitignore` |

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig -n cert-manager get pods
kubectl --kubeconfig ./kubeconfig get clusterissuers
kubectl --kubeconfig ./kubeconfig get certificates -A
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
- Адрес 192.168.91.220 закреплён за сервисом шлюза `cilium-gateway-lab` аннотацией `metallb.io/loadBalancerIPs`; остальные адреса пула свободны.

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
- хранилище;
- наблюдаемость (метрики, логи);
- механизм запуска и сброса сценариев тренажёра.

## Статус

Кластер Talos `lab` (1 control plane и 2 worker-узла) развёрнут скриптом `bootstrap.sh` и работает. В кластере установлены Cilium, Argo CD, MetalLB, Gateway API и cert-manager, приложения `root`, `argocd`, `cilium`, `metallb`, `metallb-config`, `gateway-api-crds`, `gateway`, `cert-manager` и `cert-manager-config` — `Synced` и `Healthy`. Единственный сервис типа `LoadBalancer` — шлюз `lab` (192.168.91.220); через него из локальной сети по HTTPS доступны Argo CD (https://argocd.lab.home.arpa) и Hubble UI (https://hubble.lab.home.arpa), запросы по HTTP перенаправляются на HTTPS. Прикладные компоненты и остальные открытые вопросы — впереди.

## Журнал изменений

- 2026-10-03 — Proxmox VE обновлён до версии 9.2.21.
- 2026-10-03 — зафиксированы статические IP-адреса узлов Talos на роутере: master — 192.168.91.201, worker-узлы — 192.168.91.211 и 192.168.91.212.
- 2026-10-03 — вручную поднят кластер Talos `lab`: Talos v1.14.2, Kubernetes v1.37.1, все три узла `Ready`.
- 2026-10-05 — кластер `lab` пересоздан через Terraform (провайдеры `bpg/proxmox` и `siderolabs/talos`): Talos v1.14.2, Kubernetes v1.37.0, узлы `talos-cp1`, `talos-w1`, `talos-w2`. Провижининг перенесён из открытых вопросов в принятые решения.
- 2026-10-05 — в кластер установлен Argo CD v3.5.3 (чарт `argo-cd` 10.9.6), создано корневое приложение `root` по схеме app of apps. Доставка приложений перенесена из открытых вопросов в принятые решения.
- 2026-10-06 — через Argo CD установлен MetalLB v0.16.1 (чарт `metallb` 0.16.1) в режиме L2 с пулом адресов 192.168.91.220–192.168.91.230. Балансировка перенесена из открытых вопросов в принятые решения.
- 2026-10-07 — CNI кластера заменён на Cilium v1.20.2 (чарт `cilium` 1.20.2) с Hubble: встроенные Flannel и kube-proxy отключены в machine config, добавлено приложение Argo CD `cilium`. CNI перенесён из открытых вопросов в принятые решения.
- 2026-10-07 — добавлен скрипт `bootstrap.sh`, поднимающий кластер с нуля (Terraform, Cilium, Argo CD, секрет доступа к репозиторию, корневое приложение). Кластер `lab` пересоздан этим скриптом.
- 2026-10-07 — у ВМ включено устройство QEMU guest agent: без него узлы с расширением `qemu-guest-agent` оставались в стадии `Booting`.
- 2026-10-07 — установлен Gateway API v1.6.1 в реализации Cilium: приложения Argo CD `gateway-api-crds` и `gateway`, шлюз `lab` на 192.168.91.220 (HTTP, `*.lab.home.arpa`). Argo CD и Hubble UI опубликованы по именам `argocd.lab.home.arpa` и `hubble.lab.home.arpa`; `argocd-server` переведён в режим без TLS. В `bootstrap.sh` добавлена установка CRD Gateway API перед Cilium. Ingress перенесён из открытых вопросов в принятые решения.
- 2026-10-08 — через Argo CD установлен cert-manager v1.21.2 (чарт `cert-manager` v1.21.2) с поддержкой Gateway API, создан собственный центр сертификации стенда: `ClusterIssuer` `selfsigned-bootstrap`, корневой сертификат `lab-root-ca`, рабочий издатель `lab-ca`.
- 2026-10-08 — шлюз `lab` переведён на HTTPS: добавлен listener `https` (порт 443) с сертификатом `*.lab.home.arpa` от `lab-ca`, маршруты `argocd` и `hubble` привязаны к нему, HTTP оставлен только для перенаправления на HTTPS (`HTTPRoute` `http-to-https`). TLS для входящего трафика перенесён из открытых вопросов в принятые решения.
