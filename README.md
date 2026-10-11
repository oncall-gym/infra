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
| State Terraform | Удалённый: бакет `lab-tfstate-2a7416` в Object Storage cloud.ru (S3) с версионированием и блокировкой через `use_lockfile` |
| Облачные ресурсы | Object Storage cloud.ru: бакеты для state Terraform и для снимков etcd, описаны в Terraform в каталоге `cloud/` |
| Локальное окружение | direnv: `.envrc` (в Git, без секретов) задаёт пути к конфигам и профиль AWS, токен Proxmox подставляется из системного keyring |
| Развёртывание с нуля | Скрипт `bootstrap.sh`: Terraform, затем CRD Gateway API и Cilium, затем Argo CD; корневой сертификат стенда восстанавливается из локальной копии, ключ age для расшифровки секретов кладётся в кластер |
| Сеть кластера (CNI) | Cilium v1.20.2 вместо встроенных Flannel и kube-proxy, с Hubble (relay и UI) |
| Доставка приложений | Argo CD v3.5.3 (GitOps, схема app of apps), манифесты — в каталоге `gitops/` |
| Вход в Argo CD | Через GitHub (OAuth, встроенный Dex); локальная учётная запись `admin` отключена |
| Балансировка (сервисы `LoadBalancer`) | MetalLB v0.16.1, режим L2, пул адресов 192.168.91.220–192.168.91.230 |
| Входящий трафик (ingress) | Gateway API v1.6.1 в реализации Cilium: общий шлюз `lab` на 192.168.91.220, HTTPS (HTTP перенаправляется на HTTPS), имена `*.lab.home.arpa` |
| TLS и сертификаты | cert-manager v1.21.2 с собственным центром сертификации стенда (`ClusterIssuer` `lab-ca`); TLS завершается на шлюзе, сертификат — `*.lab.home.arpa` |
| Секреты в Git | SOPS с ключом age: зашифрованные объекты `SopsSecret` в `gitops/secrets`, в кластере их расшифровывает sops-secrets-operator 0.21.2 |
| Наблюдаемость (метрики и алерты) | Чарт `victoria-metrics-k8s-stack` 0.95.2: VictoriaMetrics v1.153.0 вместо Prometheus, Alertmanager (уведомления по почте), Grafana 13.2.3 на https://grafana.lab.home.arpa |
| Резервное копирование etcd | `talos-backup` (`CronJob` в кластере): снимок etcd каждые 3 часа, сжатие zstd и шифрование age, выгрузка в бакет `lab-etcd-backup-2a7416` в Object Storage cloud.ru; восстановление — по runbook `docs/runbooks/etcd-restore.md` |

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
| `backend.tf` | хранение state в S3 cloud.ru: бакет `lab-tfstate-2a7416`, ключ `talos/terraform.tfstate` | да |
| `.terraform.lock.hcl` | зафиксированные версии провайдеров | да |
| `terraform.tfvars` | installer image и параметры нод (VMID, IP, MAC, CPU, RAM) | нет |
| `terraform.tfstate`, `terraform.tfstate.backup` | остатки локального state после переноса в S3: первый файл пуст, во втором — последняя локальная копия state с секретами кластера | нет |
| `kubeconfig`, `talosconfig` | клиентские конфиги, выгруженные из выходов Terraform | нет |
| `bootstrap.sh` | развёртывание кластера с нуля (см. «Развёртывание с нуля») | да |
| `.sops.yaml` | правила шифрования `sops` для файлов `*.enc.yaml` (см. «Секреты (SOPS)») | да |
| `.envrc` | окружение для direnv: пути к конфигам и профиль AWS, без секретов (см. «Локальное окружение (direnv)») | да |
| `.envrc.local` | личные и секретные настройки direnv: токен Proxmox из keyring | нет |
| `cloud/` | отдельная Terraform-конфигурация бакетов cloud.ru (см. «Облачное хранилище (cloud.ru)») | да |
| `docs/runbooks/etcd-restore.md` | runbook восстановления etcd из снимка (см. «Резервное копирование etcd») | да |
| `.restore/` | рабочий каталог для восстановления etcd: скачанные и расшифрованные снимки | нет |

Особенности конфигурации:

- ВМ загружаются по UEFI (OVMF), диск — `scsi0` на `local-lvm` (20 ГБ), ISO Talos (`local:iso/talos.iso`) подключён как `ide3`.
- Установка на диск описана документом `UnattendedInstallConfig` (Talos 1.14), образ установщика берётся с `factory.talos.dev` и задаётся переменной `talos_installer_image`.
- Имена узлов задаются документом `HostnameConfig`: `talos-<ключ ноды>`.
- У ВМ включено устройство QEMU guest agent (таймаут ожидания — 2 минуты). В образе Talos есть расширение `qemu-guest-agent`: без устройства агента его служба не стартует, и узел навсегда остаётся в стадии `Booting`.
- Встроенные Flannel и kube-proxy отключены под Cilium: в machine config control plane добавлены удаление документа `KubeFlannelCNIConfig` и `KubeProxyConfig` с `enabled: false`. Это настройки кластера, поэтому в конфигурацию worker-узлов они не попадают.
- Там же, в machine config control plane, включён доступ к Talos API из кластера — документ `KubeTalosAPIAccessConfig`: только для подов из namespace `talos-backup` и только с ролью `os:etcd:backup`. Через него `talos-backup` снимает снимки etcd (см. «Резервное копирование etcd»).
- Секреты кластера (`talos_machine_secrets`) и сгенерированные machine config хранятся только в state; отдельных файлов `controlplane.yaml` и `worker.yaml` больше нет.
- State удалённый: лежит в бакете `lab-tfstate-2a7416` в Object Storage cloud.ru под ключом `talos/terraform.tfstate` (`backend.tf`). В бакете включено версионирование, так что испорченный state можно откатить. От одновременных запусков защищает блокировка `use_lockfile`: на время операции рядом со state создаётся файл `.tflock`.
- Для доступа к state нужен профиль AWS CLI `cloudru` (см. «Облачное хранилище (cloud.ru)»): без него не работают `terraform init`, `plan` и `apply`.

Использование (переменные окружения выставляет direnv, см. «Локальное окружение (direnv)»):

```sh
terraform init
terraform plan
terraform apply

terraform output -raw kubeconfig > kubeconfig
terraform output -raw talosconfig > talosconfig
```

Токен API Proxmox передаётся только через переменную окружения `TF_VAR_proxmox_api_token` и в файлы репозитория не записывается. Без direnv её нужно выставить вручную: `export TF_VAR_proxmox_api_token='terraform@pve!tf=<uuid>'`.

## Локальное окружение (direnv)

Переменные окружения для работы со стендом выставляет [direnv](https://direnv.net/) при входе в каталог репозитория. После клонирования и после каждого изменения `.envrc` его нужно разрешить командой `direnv allow`.

Файл `.envrc` лежит в Git: в нём нет секретов, только пути к ним.

| Переменная | Значение | Зачем |
| --- | --- | --- |
| `KUBECONFIG` | `./kubeconfig` | `kubectl` и `helm` работают с кластером `lab` без флага `--kubeconfig` |
| `TALOSCONFIG` | `./talosconfig` | `talosctl` работает без флага `--talosconfig` |
| `SOPS_AGE_KEY_FILE` | `~/.lab/age.key` | `sops` находит ключ age (см. «Секреты (SOPS)») |
| `AWS_PROFILE` | `cloudru` | AWS CLI и Terraform ходят в S3 cloud.ru |
| `TF_INPUT` | `0` | Terraform не задаёт вопросов интерактивно: без токена Proxmox сразу завершается с ошибкой |

Личные и секретные настройки лежат в файле `.envrc.local`, который `.envrc` подключает, если он есть. В Git он не попадает (внесён в `.gitignore`).

Токен API Proxmox:

- Хранится в Bitwarden, запись `terraform@pve!tf`.
- Скрипт `lab-secrets-sync` (`~/.local/bin`, вне репозитория) копирует его из Bitwarden в системный keyring. Нужны утилиты `bw` и `secret-tool`. Скрипт запускают на новой машине и после ротации токена.
- `.envrc.local` читает токен из keyring (`secret-tool lookup service lab key proxmox-api-token`) и выставляет `TF_VAR_proxmox_api_token`. На диске в открытом виде токен не лежит.
- Если токена в keyring нет, direnv выводит ошибку с подсказкой: `lab-secrets-sync && direnv reload`.

## Облачное хранилище (cloud.ru)

Вне Proxmox у стенда есть два бакета в Object Storage cloud.ru (S3-совместимое хранилище). Они описаны отдельной Terraform-конфигурацией в каталоге `cloud/` со своим state.

| Параметр | Значение |
| --- | --- |
| Сервис | Object Storage cloud.ru, endpoint `https://s3.cloud.ru`, регион `ru-central-1` |
| Провайдер `hashicorp/aws` | 6.68.0 (направлен на S3 cloud.ru) |
| Провайдер `hashicorp/random` | 3.9.1 (суффикс в именах бакетов) |
| Доступ | профиль AWS CLI `cloudru`: настройки — в `~/.aws/config`, ключи доступа — в `~/.aws/credentials` |
| State | тот же бакет `lab-tfstate-2a7416`, ключ `cloud/terraform.tfstate` (`cloud/backend.tf`) |

Бакеты:

| Бакет | Назначение | Настройки |
| --- | --- | --- |
| `lab-tfstate-2a7416` | state Terraform: `talos/terraform.tfstate` (кластер) и `cloud/terraform.tfstate` (сами бакеты) | версионирование |
| `lab-etcd-backup-2a7416` | снимки etcd (префикс `etcd/`, см. «Резервное копирование etcd») | версионирование; Object Lock: 14 дней в режиме `GOVERNANCE`; правило жизненного цикла `expire-old`: объекты удаляются через 30 дней, прежние версии — через 7 дней |

Файлы:

| Файл | Назначение |
| --- | --- |
| `cloud/main.tf` | провайдеры, оба бакета и их настройки, выходы `tfstate_bucket` и `etcd_backup_bucket` |
| `cloud/backend.tf` | хранение state этой конфигурации в S3 |
| `cloud/.terraform.lock.hcl` | зафиксированные версии провайдеров |

Особенности:

- У cloud.ru нет сервисов AWS STS, IAM и метаданных EC2, поэтому в провайдере и в обоих `backend.tf` отключены обращения к ним (`skip_credentials_validation`, `skip_region_validation`, `skip_requesting_account_id`, `skip_metadata_api_check`), а в backend ещё и `skip_s3_checksum`. Адресация — в стиле пути (`use_path_style`).
- Object Lock включается только при создании бакета. 14 дней каждый снимок etcd нельзя ни удалить, ни перезаписать. Режим `GOVERNANCE` в крайнем случае позволяет администратору (`s3e.admin`) снять блокировку; в режиме `COMPLIANCE` этого не мог бы никто.
- Правило жизненного цикла записывается не ресурсом `aws_s3_bucket_lifecycle_configuration`, а командой AWS CLI из `terraform_data` `etcd_lifecycle`: ресурс провайдера ждёт в ответе поля, которых S3 cloud.ru не возвращает. При изменении JSON правила команда выполняется заново. Поэтому для `terraform apply` в `cloud/` нужна утилита `aws`.
- Бакет для state создаёт эта же конфигурация, поэтому `cloud/backend.tf` добавлен уже после создания бакетов: сначала state был локальным, затем перенесён в бакет.
- Имена бакетов записаны в `backend.tf` и `cloud/backend.tf` строкой: backend не умеет читать выходы Terraform. Если бакет пересоздать, суффикс изменится, и имя нужно поправить в обоих файлах.
- В бакет для снимков etcd пишет `talos-backup` из кластера (см. «Резервное копирование etcd»). У него отдельные ключи доступа — сервисного аккаунта cloud.ru `sa-etcd-backup`. Профиль `cloudru` работает с ключами сервисного аккаунта `sa-lab-admin`. Оба сервисных аккаунта и их ключи заведены в консоли cloud.ru: в Terraform их нет.

Использование:

```sh
cd cloud
terraform init
terraform plan
terraform apply
terraform output
```

## Развёртывание с нуля

Скрипт `bootstrap.sh` поднимает кластер целиком одной командой. Всё, что не входит в его шаги, Argo CD ставит сам из Git.

Шаги скрипта:

1. Проверка окружения до любых изменений: есть ли файл ключа age, утилиты `terraform`, `kubectl`, `helm`, `jq` и файл deploy-ключа. Если чего-то нет, скрипт сразу завершается с ошибкой.
2. `terraform apply -parallelism=1` — ВМ и кластер Talos. Terraform запрашивает подтверждение как обычно.
3. Выгрузка `kubeconfig` и `talosconfig` из выходов Terraform в корень репозитория.
4. Ожидание готовности API-сервера.
5. Установка типов ресурсов (CRD) Gateway API v1.6.1: `kubectl apply --server-side` файла `standard-install.yaml` из релиза `kubernetes-sigs/gateway-api`. Они нужны до Cilium: оператор создаёт `GatewayClass` `cilium`, только если CRD уже есть на момент его запуска. Шаг пропускается, если CRD `gateways.gateway.networking.k8s.io` уже есть в кластере.
6. Установка Cilium через Helm в `kube-system` со значениями из `gitops/cilium/values.yaml`. Без CNI узлы остаются `NotReady`, поэтому Cilium ставится раньше остальных компонентов. Шаг пропускается, если в кластере уже есть приложение Argo CD `cilium`.
7. Ожидание регистрации трёх узлов и их состояния `Ready`.
8. Установка Argo CD через Helm в `argocd` со значениями из `gitops/argocd/values.yaml`. Шаг пропускается, если в кластере уже есть приложение Argo CD `argocd`.
9. Создание секрета `repo-local-infra` с SSH-ключом доступа к репозиторию.
10. Создание namespace `cert-manager` и восстановление секрета `lab-root-ca` (корневой сертификат стенда с приватным ключом) из локальной копии — до того, как cert-manager появится в кластере, иначе он выпустит новый корневой сертификат. Если копии нет, шаг пропускается; если секрет уже есть в кластере, он не перезаписывается.
11. Создание namespace `sops-secrets-operator` и секрета `sops-age-key-file` с приватным ключом age — им оператор расшифровывает секреты из Git (см. «Секреты (SOPS)»).
12. Применение корневого приложения `gitops/root.yaml`.
13. Только если локальной копии не было: ожидание, пока cert-manager создаст секрет `lab-root-ca` (до 15 минут), и сохранение его в локальную копию для следующих пересозданий. Если секрет за это время не появился, скрипт завершается с ошибкой: кластер при этом поднят, копию нужно сохранить вручную.

Что нужно до запуска:

- установленные `terraform`, `kubectl`, `helm` и `jq`, выполненный `terraform init`;
- заполненный `terraform.tfvars` и переменная окружения `TF_VAR_proxmox_api_token` (её выставляет direnv, см. «Локальное окружение (direnv)»);
- профиль AWS CLI `cloudru` с доступом к бакету `lab-tfstate-2a7416`: в нём лежит state Terraform (см. «Облачное хранилище (cloud.ru)»);
- ISO Talos в хранилище Proxmox (`local:iso/talos.iso`);
- доступ к `github.com` с машины, где запускается скрипт (оттуда скачивается манифест CRD Gateway API);
- приватный SSH-ключ доступа Argo CD к репозиторию. Путь задаётся переменной окружения `DEPLOY_KEY`, по умолчанию — `~/argocd-deploy-key`;
- по желанию — локальная копия секрета `lab-root-ca`, чтобы сохранить прежний корневой сертификат. Путь задаётся переменной окружения `CA_SECRET`, по умолчанию — `~/.lab/lab-root-ca-secret.json`. При первом запуске без копии скрипт создаёт её сам;
- приватный ключ age, которым зашифрованы секреты в `gitops/secrets`. Путь задаётся переменной окружения `AGE_KEY`, по умолчанию — `~/.lab/age.key`. Без него скрипт не стартует: создать ключ заново нельзя, иначе секреты из Git не расшифруются.

Запуск (в каталоге репозитория с разрешённым direnv; без него сначала выставь `TF_VAR_proxmox_api_token` вручную):

```sh
./bootstrap.sh
```

Особенности:

- Скрипт можно запускать повторно, в том числе на работающем кластере. То, чем уже управляет Argo CD, он не трогает: CRD Gateway API ставятся, только если их ещё нет, Helm-релизы `cilium` и `argocd` — только если нет одноимённых приложений Argo CD. Секрет `repo-local-infra`, namespace `cert-manager` и `sops-secrets-operator`, секрет `sops-age-key-file` и корневое приложение применяются через `kubectl apply`.
- Версии чартов заданы в двух местах и должны совпадать: `CILIUM_VERSION` — с `targetRevision` в `gitops/apps/cilium.yaml`, `ARGOCD_VERSION` — с `targetRevision` в `gitops/apps/argocd.yaml`. Иначе Argo CD после установки сразу приведёт релиз к версии из Git.
- Версия Gateway API тоже задана дважды: в переменной `GATEWAY_API_VERSION` в `bootstrap.sh` и в `targetRevision` приложения `gitops/apps/gateway-api-crds.yaml`. Обе должны совпадать и соответствовать версии, под которую собран Cilium.
- После шага 12 Argo CD берёт под своё управление установленные скриптом релизы `cilium` и `argocd` и типы ресурсов Gateway API (приложение `gateway-api-crds`).
- cert-manager и центр сертификации стенда скрипт не ставит: их разворачивает Argo CD. Скрипт только переносит между пересозданиями кластера секрет `lab-root-ca`: с восстановленным секретом корневой сертификат остаётся прежним, и доверие на клиентских машинах настраивать заново не нужно (см. «Сертификаты (cert-manager)»).
- Локальная копия секрета сохраняется в формате JSON без служебных полей (`uid`, `resourceVersion`, `creationTimestamp`, `managedFields`, `ownerReferences`), с правами только для владельца. В ней лежит приватный ключ центра сертификации: скрипт советует скопировать файл в менеджер паролей.
- sops-secrets-operator скрипт не ставит: его разворачивает Argo CD. Скрипт только кладёт в кластер ключ age до применения корневого приложения, чтобы оператор сразу смог расшифровать секреты.
- Argo CD ставится сразу с отключённой учётной записью `admin` и входом через GitHub. Войти в интерфейс получится, только когда Argo CD развернёт sops-secrets-operator и приложение `platform-secrets`, а оператор создаст секрет `argocd-github-oauth` (см. «Вход в Argo CD»).

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
| `gitops/gateway/routes.yaml` | маршруты `HTTPRoute` к Argo CD и Hubble UI и перенаправление с HTTP на HTTPS |
| `gitops/gateway/grafana-route.yaml` | маршрут `HTTPRoute` к Grafana |
| `gitops/apps/cert-manager.yaml` | приложение `cert-manager`: Helm-чарт cert-manager (значения — в самом манифесте) |
| `gitops/apps/cert-manager-config.yaml` | приложение `cert-manager-config`: следит за каталогом `gitops/cert-manager` |
| `gitops/cert-manager/issuers.yaml` | центр сертификации стенда: издатели `ClusterIssuer` и корневой сертификат |
| `gitops/apps/sops-secrets-operator.yaml` | приложение `sops-secrets-operator`: Helm-чарт оператора (значения — в самом манифесте) |
| `gitops/apps/platform-secrets.yaml` | приложение `platform-secrets`: следит за каталогом `gitops/secrets` |
| `gitops/secrets/argocd-github-oauth.enc.yaml` | зашифрованный `SopsSecret`: данные приложения GitHub OAuth для входа в Argo CD |
| `gitops/secrets/alertmanager-config.enc.yaml` | зашифрованный `SopsSecret`: конфигурация Alertmanager |
| `gitops/secrets/talos-backup-s3.enc.yaml` | зашифрованный `SopsSecret`: ключи доступа к бакету со снимками etcd |
| `gitops/apps/monitoring.yaml` | приложение `monitoring`: Helm-чарт `victoria-metrics-k8s-stack` (значения — в самом манифесте) |
| `gitops/apps/talos-backup.yaml` | приложение `talos-backup`: следит за каталогом `gitops/talos-backup` |
| `gitops/talos-backup/cronjob.yaml` | `CronJob` `talos-backup`: снимки etcd по расписанию |
| `gitops/talos-backup/talos-serviceaccount.yaml` | `ServiceAccount` Talos (`talos.dev/v1alpha1`): доступ к Talos API с ролью `os:etcd:backup` |
| `gitops/talos-backup/alerts.yaml` | `VMRule` `talos-backup`: алерты на устаревший или отсутствующий снимок |

Как это работает:

- Приложение `root` применяет всё, что лежит в `gitops/apps`. Чтобы добавить компонент в кластер, достаточно положить туда манифест `Application` и отправить коммит в `main`.
- У всех приложений включена автоматическая синхронизация с `prune` и `selfHeal`: ручные правки в кластере откатываются, а удалённое из Git удаляется из кластера. Исключение — `gateway-api-crds`: у него `prune` отключён, чтобы типы ресурсов не удалялись автоматически.
- Для экономии памяти в чарте отключён контроллер уведомлений. Dex включён: через него работает вход по GitHub (см. «Вход в Argo CD»).
- `argocd-server` работает без TLS (`configs.params.server.insecure: true`): TLS завершается на шлюзе, а в сервис шлюз ходит по HTTP.
- Доступ к репозиторию — по SSH-ключу из секрета `repo-local-infra` в namespace `argocd`. Секрет создаёт `bootstrap.sh`, в Git он не хранится.

Первичную установку Argo CD, создание секрета `repo-local-infra` и применение `gitops/root.yaml` выполняет `bootstrap.sh` (см. «Развёртывание с нуля»). Дальше Argo CD обслуживает себя сам.

Интерфейс Argo CD доступен из локальной сети по адресу https://argocd.lab.home.arpa (сервис `argocd-server` остаётся `ClusterIP`, наружу его публикует шлюз, см. «Входящий трафик (Gateway API)»).

Проверка состояния и запасной доступ к интерфейсу в обход шлюза (по HTTP: `argocd-server` работает без TLS). Войти через GitHub при таком доступе не получится: после входа GitHub возвращает на основной адрес.

```sh
kubectl --kubeconfig ./kubeconfig -n argocd get applications
kubectl --kubeconfig ./kubeconfig -n argocd port-forward svc/argocd-server 8080:80
```

### Вход в Argo CD

В интерфейс Argo CD входят через GitHub: встроенный Dex работает как клиент GitHub OAuth. Локальная учётная запись `admin` отключена. Настройки — в `gitops/argocd/values.yaml`.

| Параметр | Значение |
| --- | --- |
| Адрес Argo CD | `https://argocd.lab.home.arpa` (`global.domain` и `configs.cm.url`) |
| Коннектор Dex | `github` (`configs.cm."dex.config"`) |
| Данные приложения GitHub OAuth | секрет `argocd-github-oauth` в namespace `argocd`, ключи `clientID` и `clientSecret` |
| Адрес возврата в приложении GitHub OAuth | `https://argocd.lab.home.arpa/api/dex/callback` |
| Локальный `admin` | отключён (`configs.cm."admin.enabled": "false"`) |
| Права | `configs.rbac`: роли по умолчанию нет (`policy.default: ""`), `role:admin` выдана по адресу почты в `policy.csv` |

Особенности:

- Секрет `argocd-github-oauth` в Git лежит зашифрованным (`gitops/secrets/argocd-github-oauth.enc.yaml`), в кластере его создаёт sops-secrets-operator (см. «Секреты (SOPS)»). В `dex.config` значения подставляются ссылками вида `$argocd-github-oauth:clientID`; для этого на секрете стоит метка `app.kubernetes.io/part-of: argocd`.
- Пользователь GitHub, которого нет в `policy.csv`, войти сможет, но ничего не увидит: роли по умолчанию нет. Чтобы дать доступ, добавь строку `g, <почта>, role:admin` в `configs.rbac."policy.csv"`. Почта берётся из учётной записи GitHub (`scopes: "[groups, email]"`).
- Для входа с клиентской машины нужен доступ к `github.com`, а Dex в кластере должен доставать до API GitHub.
- Запасного входа по паролю нет. Если вход через GitHub сломался, состояние приложений смотри через `kubectl`, а `admin` возвращай правкой `gitops/argocd/values.yaml`.

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
| https://grafana.lab.home.arpa | `grafana` в namespace `monitoring` | `vmks-grafana:80` |

Как это устроено:

- Типы ресурсов Gateway API ставит приложение `gateway-api-crds` из репозитория `kubernetes-sigs/gateway-api` (тег `v1.6.1`, каталог `config/crd`). У него отключён `prune` и включён `ServerSideApply=true`: описания слишком большие для обычного `apply`.
- При развёртывании с нуля те же типы ставит `bootstrap.sh` перед Cilium: оператор Cilium создаёт `GatewayClass` `cilium`, только если CRD уже есть на момент его запуска.
- В значениях чарта Cilium включено `gatewayAPI.enabled` (а также `enableAlpn` и `enableAppProtocol`).
- Приложение `gateway` применяет каталог `gitops/gateway`: `gateway.yaml` (шлюз), `routes.yaml` (перенаправление и маршруты к Argo CD и Hubble UI) и `grafana-route.yaml` (маршрут к Grafana). Namespace `gateway` создаёт Argo CD (`CreateNamespace=true`); включены `SkipDryRunOnMissingResource=true` и повторные попытки синхронизации — на случай, когда CRD ещё не установлены.
- Адрес шлюза закреплён аннотацией `metallb.io/loadBalancerIPs: 192.168.91.220` (`spec.infrastructure.annotations` в `Gateway`): Cilium переносит её на создаваемый сервис.
- Сертификат шлюза заказывается аннотацией `cert-manager.io/cluster-issuer: lab-ca` на самом `Gateway`: cert-manager по listener `https` сам создаёт `Certificate` `lab-wildcard-tls` на имя `*.lab.home.arpa` и продлевает его. Отдельного манифеста `Certificate` в Git нет.
- `HTTPRoute` `http-to-https` в namespace `gateway` привязан к listener `http` и отвечает на любой запрос перенаправлением 301 на HTTPS. Других маршрутов на порту 80 нет: listener принимает маршруты только из своего namespace.
- Маршруты к сервисам привязаны к listener `https` (`sectionName: https` в `parentRefs`). Они лежат в каталоге `gitops/gateway` (`routes.yaml`, для Grafana — `grafana-route.yaml`), но создаются в namespace своих сервисов (`argocd`, `kube-system`, `monitoring`), поэтому `ReferenceGrant` не нужен.
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
- Namespace `cert-manager` при развёртывании с нуля создаёт `bootstrap.sh` — он нужен для секрета `lab-root-ca` ещё до установки чарта. У приложения `cert-manager` при этом остаётся `CreateNamespace=true`.
- Издатели и корневой сертификат вынесены в отдельное приложение, потому что их CRD появляются только после установки чарта. Поэтому у `cert-manager-config` включены `SkipDryRunOnMissingResource=true` и повторные попытки синхронизации.
- Центр сертификации внутренний: публичного доверия к нему нет, а ACME (Let's Encrypt) не используется — имена `*.lab.home.arpa` существуют только в локальной сети.
- Приватный ключ корневого сертификата лежит в секрете `lab-root-ca` в кластере и в его локальных копиях (см. таблицу ниже); в Git его нет.

Доверие на клиентских машинах:

- Браузеры и `curl` не доверяют сертификатам стенда, пока корневой сертификат не добавлен в доверенные на клиентской машине.
- Корневой сертификат (без ключа) выгружается так:

  ```sh
  kubectl --kubeconfig ./kubeconfig -n cert-manager get secret lab-root-ca \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
  ```

- При пересоздании кластера `bootstrap.sh` восстанавливает секрет `lab-root-ca` из локальной копии (`CA_SECRET`), поэтому корневой сертификат и `lab-root-ca.crt` остаются прежними, а доверие на клиентах сохраняется.
- Если копии нет (первый запуск или файл утерян), cert-manager выпускает корневой сертификат заново с новым ключом: старый `lab-root-ca.crt` перестаёт подходить, доверие нужно настроить повторно. Новый секрет скрипт сохраняет в `CA_SECRET` сам.

Локальные файлы (не в VCS):

| Файл | Содержимое | Секрет |
| --- | --- | --- |
| `~/.lab/lab-root-ca-secret.json` | копия секрета `lab-root-ca` вместе с приватным ключом центра сертификации; её создаёт и читает `bootstrap.sh` (путь — переменная `CA_SECRET`) | да, лежит вне репозитория, права только для владельца |
| `lab-root-ca.crt` (корень репозитория) | корневой сертификат стенда — его добавляют в доверенные на клиентских машинах | нет; в VCS не попадает: в `.gitignore` внесена маска `*.crt` |
| `lab-root-ca-secret.yaml` (корень репозитория) | более ранняя ручная выгрузка того же секрета; `bootstrap.sh` её не использует | да, добавлен в `.gitignore` |

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig -n cert-manager get pods
kubectl --kubeconfig ./kubeconfig get clusterissuers
kubectl --kubeconfig ./kubeconfig get certificates -A
```

## Секреты (SOPS)

Секреты платформы хранятся в Git зашифрованными. Шифрует их утилита `sops` ключом age, а в кластере расшифровывает sops-secrets-operator: он превращает объекты `SopsSecret` в обычные `Secret`.

| Параметр | Значение |
| --- | --- |
| sops-secrets-operator | 0.21.2 |
| Helm-чарт | `sops-secrets-operator` 0.28.1 из `https://isindir.github.io/sops-secrets-operator/` |
| Namespace | `sops-secrets-operator` |
| Имя релиза | `sops` |
| Тип ресурса | `SopsSecret` (`isindir.github.com/v1alpha3`) |
| Ключ в кластере | секрет `sops-age-key-file` (ключ `key`), смонтирован в оператор как `/etc/sops-age-key-file/key` (`SOPS_AGE_KEY_FILE`) |
| Ключ локально | `~/.lab/age.key` — вне репозитория, права только для владельца |
| Правила шифрования | `.sops.yaml`: файлы `*.enc.yaml`, получатель — публичный ключ age |

Секреты в `gitops/secrets`:

| Файл | `SopsSecret` | Создаваемый `Secret` | Назначение |
| --- | --- | --- | --- |
| `argocd-github-oauth.enc.yaml` | `argocd-github-oauth` в namespace `argocd` | `argocd-github-oauth` | `clientID` и `clientSecret` приложения GitHub OAuth (см. «Вход в Argo CD») |
| `alertmanager-config.enc.yaml` | `alertmanager-config` в namespace `monitoring` | `alertmanager-config` | конфигурация Alertmanager, ключ `alertmanager.yaml` (см. «Наблюдаемость (мониторинг)») |
| `talos-backup-s3.enc.yaml` | `talos-backup-s3` в namespace `talos-backup` | `talos-backup-s3` | `AWS_ACCESS_KEY_ID` и `AWS_SECRET_ACCESS_KEY` сервисного аккаунта `sa-etcd-backup` для выгрузки снимков etcd (см. «Резервное копирование etcd») |

Как это устроено:

- Приложение `sops-secrets-operator` ставит оператор, приложение `platform-secrets` применяет каталог `gitops/secrets`. Argo CD кладёт объекты `SopsSecret` в кластер как есть, не расшифровывая. У `platform-secrets` включены `SkipDryRunOnMissingResource=true` и повторные попытки синхронизации — на случай, когда CRD оператора ещё не установлен.
- Шифруется не весь файл, а только поля с суффиксом `Templates` (`encrypted_suffix` в `.sops.yaml`), то есть раздел `spec.secretTemplates`. Тип, имя и namespace объекта `SopsSecret` остаются читаемыми.
- Приватный ключ age в Git не хранится. В кластер его кладёт `bootstrap.sh` (секрет `sops-age-key-file`) до применения корневого приложения. Ключ один на все пересоздания кластера: если его потерять, файлы из `gitops/secrets` расшифровать будет нечем, и секреты придётся создавать заново.
- В `.sops.yaml` записан только публичный ключ age — он не секрет.

Работа с секретами (нужны утилиты `sops` и `age`):

```sh
export SOPS_AGE_KEY_FILE=~/.lab/age.key

# Изменить существующий секрет: sops расшифрует его в редакторе и зашифрует при сохранении
sops gitops/secrets/alertmanager-config.enc.yaml

# Добавить новый: написать манифест SopsSecret в открытом виде и зашифровать на месте
sops --encrypt --in-place gitops/secrets/<имя>.enc.yaml
```

Имя файла должно заканчиваться на `.enc.yaml`, иначе правило из `.sops.yaml` не сработает. Перед коммитом проверь, что в `spec.secretTemplates` стоят значения `ENC[...]`.

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig -n sops-secrets-operator get pods
kubectl --kubeconfig ./kubeconfig get sopssecrets -A
```

У всех объектов `SopsSecret` должен быть статус `Healthy`.

## Наблюдаемость (мониторинг)

Метрики, алерты и дашборды ставятся одним чартом `victoria-metrics-k8s-stack` через приложение Argo CD `monitoring`. Вместо Prometheus используется VictoriaMetrics: при той же совместимости он заметно экономнее по памяти. Сбор логов пока не настроен (см. «Открытые вопросы»).

| Параметр | Значение |
| --- | --- |
| Helm-чарт | `victoria-metrics-k8s-stack` 0.95.2 из `https://victoriametrics.github.io/helm-charts/` |
| Namespace | `monitoring` |
| Имя релиза | `vmks` (`fullnameOverride: vmks`) |
| Оператор | VictoriaMetrics operator v0.75.0 |
| Хранение метрик | `VMSingle` `vmks`, VictoriaMetrics v1.153.0, срок хранения — 7 дней, том `emptyDir` |
| Сбор метрик | `VMAgent` `vmks` v1.153.0 |
| Правила и алерты | `VMAlert` `vmks` v1.153.0 |
| Уведомления | Alertmanager v0.34.0 (`VMAlertmanager` `vmks`), по почте |
| Дашборды | Grafana 13.2.3 — https://grafana.lab.home.arpa |
| Экспортёры | node-exporter v1.12.1 (на всех трёх узлах), kube-state-metrics v2.20.0 |

Особенности (значения чарта — в `gitops/apps/monitoring.yaml`):

- Постоянного хранилища в кластере нет (см. «Открытые вопросы»), поэтому метрики лежат в `emptyDir`: у `VMSingle` отключён `storage` и том `data` задан явно. При пересоздании пода `vmsingle-vmks` накопленные метрики теряются.
- Отключён сбор метрик etcd, планировщика, controller manager и kube-proxy (`kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`): kube-proxy в кластере нет (его заменяет Cilium), метрики остальных трёх компонентов не собираются.
- Namespace `monitoring` создаёт Argo CD (`CreateNamespace=true`) с меткой `pod-security.kubernetes.io/enforce: privileged`: node-exporter читает данные хоста, а Talos по умолчанию применяет профиль `baseline`.
- У приложения включён `ServerSideApply=true`: описания типов ресурсов оператора слишком большие для обычного `apply`.
- Пароль администратора Grafana чарт генерирует заново при каждой отрисовке, поэтому поле `/data/admin-password` секрета `vmks-grafana` исключено из сравнения (`ignoreDifferences` и `RespectIgnoreDifferences=true`). Иначе приложение всегда было бы `OutOfSync`.
- Grafana опубликована через общий шлюз: `HTTPRoute` `grafana` в namespace `monitoring` (`gitops/gateway/grafana-route.yaml`), сервис `vmks-grafana:80` остаётся `ClusterIP`.

Алерты и уведомления:

- Конфигурацию Alertmanager берёт из секрета `alertmanager-config` (`alertmanager.spec.configSecret`), а не из значений чарта. Секрет создаёт sops-secrets-operator из `gitops/secrets/alertmanager-config.enc.yaml`: в конфигурации лежат адрес и пароль почтового сервера, поэтому в Git она зашифрована.
- Получатель по умолчанию — `email`: письма через SMTP. Алерты группируются по `alertname` и `namespace`, повтор — раз в 4 часа.
- Алерты с `severity = "info"` и служебный `InfoInhibitor` уходят получателю `blackhole`, то есть письма по ним не отправляются.
- `Watchdog` (постоянно активный алерт-проверка) отправляется раз в минуту на внешний webhook — получатель `deadmans-switch`. Если сигналы перестают приходить, значит, не работает сам мониторинг.
- Чтобы изменить получателей или маршруты, отредактируй зашифрованный файл через `sops` (см. «Секреты (SOPS)») и отправь коммит в `main`.

Вход в Grafana — пользователь `admin`, пароль лежит в секрете `vmks-grafana`:

```sh
kubectl --kubeconfig ./kubeconfig -n monitoring get secret vmks-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Проверка состояния:

```sh
kubectl --kubeconfig ./kubeconfig -n monitoring get pods
kubectl --kubeconfig ./kubeconfig -n monitoring get vmsingle,vmagent,vmalert,vmalertmanager
```

## Резервное копирование etcd

Снимки etcd снимает [talos-backup](https://github.com/siderolabs/talos-backup) — утилита Sidero Labs, которая работает в кластере как `CronJob`, получает снимок через Talos API и выгружает его в S3. Манифесты — в каталоге `gitops/talos-backup`, приложение Argo CD — `talos-backup`.

| Параметр | Значение |
| --- | --- |
| Образ | `ghcr.io/siderolabs/talos-backup:v0.1.0-beta.3-10-gb9fd478` |
| Namespace | `talos-backup` |
| Расписание | `15 */3 * * *` — каждые 3 часа; пропущенный запуск догоняется в течение часа, параллельные запуски запрещены |
| Куда | бакет `lab-etcd-backup-2a7416`, ключи вида `etcd/lab-<время в UTC>.snap.zst.age` |
| Обработка | сжатие zstd, затем шифрование age отдельным ключом резервных копий |
| Срок хранения | 30 дней; первые 14 дней снимок нельзя удалить или перезаписать (Object Lock, см. «Облачное хранилище (cloud.ru)») |
| RPO | до 3 часов (интервал между снимками) |
| Восстановление | runbook [docs/runbooks/etcd-restore.md](docs/runbooks/etcd-restore.md), последняя проверка — 2026-10-11 |

Как это устроено:

- Доступ к Talos API из пода разрешён документом `KubeTalosAPIAccessConfig` в machine config control plane (`main.tf`): только namespace `talos-backup` и только роль `os:etcd:backup`. Ничего, кроме снимка etcd, с этим доступом сделать нельзя.
- Объект `ServiceAccount` Talos (`talos.dev/v1alpha1`, `talos-serviceaccount.yaml`) запрашивает эту роль. Talos создаёт по нему секрет `talos-backup-secrets` с конфигом для доступа к API; он смонтирован в под как `/var/run/secrets/talos.dev`.
- Ключи доступа к бакету лежат в секрете `talos-backup-s3`, который sops-secrets-operator создаёт из `gitops/secrets/talos-backup-s3.enc.yaml` (см. «Секреты (SOPS)»). Это ключи сервисного аккаунта cloud.ru `sa-etcd-backup`.
- Снимок шифруется публичным ключом age, записанным в `cronjob.yaml` (`AGE_RECIPIENT_PUBLIC_KEY`). Это отдельный ключ, не тот, которым зашифрованы секреты в Git. Приватный ключ лежит только локально в `~/.lab/etcd-backup.age.key` и в Bitwarden, в кластере его нет: с доступом к кластеру или к бакету снимок не прочитать. Если ключ потерять, снимки расшифровать будет нечем.
- Под работает без прав root, со сброшенными capabilities; запрошено 50m CPU и 64 МиБ памяти, предел памяти — 512 МиБ. Задание прерывается через 15 минут, повторных попыток — две.
- Снимок занимает около 27 МБ, после сжатия и шифрования — около 3 МБ.

Алерты (`VMRule` `talos-backup` в namespace `monitoring`, `gitops/talos-backup/alerts.yaml`):

| Алерт | Условие |
| --- | --- |
| `EtcdBackupTooOld` | последний успешный снимок старше 16 часов (в течение 15 минут). Порог выше интервала, потому что кластер выключается на ночь |
| `EtcdBackupNeverSucceeded` | у `CronJob` в течение 12 часов не было ни одного успешного запуска |

Оба — уровня `warning` и приходят по почте. Упавшее задание дополнительно ловит стандартный алерт `KubeJobFailed` из чарта мониторинга.

Восстановление:

- Порядок действий — в runbook [docs/runbooks/etcd-restore.md](docs/runbooks/etcd-restore.md): выбор и расшифровка снимка, очистка раздела `EPHEMERAL` на control plane, `talosctl bootstrap --recover-from`, перезапуск Cilium, уборка устаревших объектов, проверка.
- Снимки скачиваются и расшифровываются в каталоге `.restore/` в корне репозитория (внесён в `.gitignore`). Расшифрованный снимок содержит все секреты кластера: после восстановления его нужно удалить.
- Снимок подходит только к кластеру с прежними секретами Talos (они лежат в state Terraform). Если кластер пересоздан с новыми секретами, сертификаты узлов не совпадут со снимком.
- После восстановления обязательно перезапусти Cilium на всех узлах (`kubectl -n kube-system rollout restart ds/cilium`): пока API-сервер недоступен, агенты на worker-узлах теряют адрес сервиса `kubernetes` и сами его не возвращают. Узлы при этом остаются `Ready`, приложения Argo CD — `Healthy`, а поды на worker-узлах не достают до API.
- Учебное восстановление 2026-10-11 (очистка `EPHEMERAL` на `talos-cp1`, снимок из S3): control plane вернулся за 5 минут, полностью рабочее состояние — через 40 минут вместе с диагностикой. По его итогам в runbook добавлены перезапуск Cilium и уборка устаревших объектов.

Проверка состояния и запуск снимка вручную:

```sh
kubectl --kubeconfig ./kubeconfig -n talos-backup get cronjob,jobs
kubectl --kubeconfig ./kubeconfig -n talos-backup create job --from=cronjob/talos-backup manual-$(date +%s)
aws --profile cloudru --endpoint-url https://s3.cloud.ru s3 ls s3://lab-etcd-backup-2a7416/etcd/
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
- хранилище в кластере (пока его нет, метрики VictoriaMetrics лежат в `emptyDir`);
- сбор логов (метрики и алерты уже есть, см. «Наблюдаемость (мониторинг)»);
- механизм запуска и сброса сценариев тренажёра.

## Статус

Кластер Talos `lab` (1 control plane и 2 worker-узла) развёрнут скриптом `bootstrap.sh` и работает. В кластере установлены Cilium, Argo CD, MetalLB, Gateway API, cert-manager, sops-secrets-operator, стек мониторинга на VictoriaMetrics и резервное копирование etcd (`talos-backup`). Приложения `root`, `argocd`, `cilium`, `metallb`, `metallb-config`, `gateway-api-crds`, `gateway`, `cert-manager`, `cert-manager-config`, `sops-secrets-operator`, `platform-secrets`, `monitoring` и `talos-backup` — `Synced` и `Healthy`. Единственный сервис типа `LoadBalancer` — шлюз `lab` (192.168.91.220); через него из локальной сети по HTTPS доступны Argo CD (https://argocd.lab.home.arpa, вход через GitHub), Hubble UI (https://hubble.lab.home.arpa) и Grafana (https://grafana.lab.home.arpa), запросы по HTTP перенаправляются на HTTPS. Алерты приходят по почте. State Terraform хранится в Object Storage cloud.ru; туда же каждые 3 часа выгружаются зашифрованные снимки etcd, восстановление из снимка проверено 2026-10-11. Прикладные компоненты и остальные открытые вопросы — впереди.

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
- 2026-10-08 — `bootstrap.sh` сохраняет корневой сертификат стенда между пересозданиями кластера: секрет `lab-root-ca` восстанавливается из локальной копии (`CA_SECRET`, по умолчанию `~/.lab/lab-root-ca-secret.json`) до запуска cert-manager, а при первом запуске без копии сохраняется в неё. Скрипт также проверяет окружение перед началом (утилиты, включая `jq`, и deploy-ключ), не переустанавливает CRD Gateway API, Cilium и Argo CD на работающем кластере; версия Gateway API вынесена в переменную `GATEWAY_API_VERSION`.
- 2026-10-08 — через Argo CD установлен sops-secrets-operator 0.21.2 (чарт `sops-secrets-operator` 0.28.1): секреты хранятся в Git зашифрованными `sops` с ключом age. `bootstrap.sh` проверяет наличие ключа (`AGE_KEY`, по умолчанию `~/.lab/age.key`) и кладёт его в кластер секретом `sops-age-key-file`.
- 2026-10-09 — добавлены правила шифрования `.sops.yaml` и приложение `platform-secrets` с каталогом `gitops/secrets`. Вход в Argo CD переведён на GitHub OAuth через Dex (секрет `argocd-github-oauth`), локальная учётная запись `admin` отключена, права выдаются в `configs.rbac`.
- 2026-10-10 — через Argo CD установлен стек мониторинга: чарт `victoria-metrics-k8s-stack` 0.95.2 (VictoriaMetrics v1.153.0, Alertmanager, Grafana 13.2.3), приложение `monitoring`. Метрики хранятся 7 дней в `emptyDir`. Grafana опубликована по адресу https://grafana.lab.home.arpa. Конфигурация Alertmanager хранится в зашифрованном секрете `alertmanager-config`: уведомления по почте, алерты уровня `info` не отправляются. Метрики и алерты перенесены из открытых вопросов в принятые решения, сбор логов остаётся открытым.
- 2026-10-10 — в `.gitignore` добавлена маска `*.crt`: `lab-root-ca.crt` больше не может попасть в репозиторий.
- 2026-10-11 — в Object Storage cloud.ru созданы бакеты `lab-tfstate-2a7416` (state Terraform, версионирование) и `lab-etcd-backup-2a7416` (снимки etcd: версионирование, Object Lock на 14 дней, удаление через 30 дней). Они описаны отдельной Terraform-конфигурацией в каталоге `cloud/`.
- 2026-10-11 — state Terraform перенесён из локальных файлов в бакет `lab-tfstate-2a7416`: кластер — ключ `talos/terraform.tfstate` (`backend.tf`), бакеты — `cloud/terraform.tfstate` (`cloud/backend.tf`), блокировка через `use_lockfile`.
- 2026-10-11 — добавлен `.envrc` для direnv: `KUBECONFIG`, `TALOSCONFIG`, `SOPS_AGE_KEY_FILE`, `AWS_PROFILE` и `TF_INPUT`. Токен Proxmox подставляется из системного keyring через `.envrc.local` (в `.gitignore`), в keyring его кладёт скрипт `lab-secrets-sync` из Bitwarden.
- 2026-10-11 — настроено резервное копирование etcd: `talos-backup` (`CronJob` в namespace `talos-backup`, приложение Argo CD `talos-backup`) каждые 3 часа снимает снимок, сжимает его zstd, шифрует age и выгружает в бакет `lab-etcd-backup-2a7416`. В machine config control plane добавлен `KubeTalosAPIAccessConfig` (роль `os:etcd:backup` для namespace `talos-backup`), ключи доступа к бакету — в зашифрованном секрете `talos-backup-s3`, алерты `EtcdBackupTooOld` и `EtcdBackupNeverSucceeded`. Резервное копирование etcd перенесено из открытых вопросов в принятые решения.
- 2026-10-11 — проведено учебное восстановление etcd из снимка, по его итогам написан runbook `docs/runbooks/etcd-restore.md`. В `.gitignore` добавлен каталог `.restore/`.
