# Требования маркетплейсов: где выполнены и что не проверено

Источники. **Yandex Cloud** — документация `github.com/yandex-cloud/docs` (ru/marketplace: `operations/create-product.md`,
`operations/create-new-version.md`, `concepts/compute-product.md`, `_includes/compute/image-create-requirements*.md`,
`_includes/marketplace/product-version-compute.md`, `product-info.md`, `links.md`, `terms.md`) и скрипт
`yandex-cloud/marketplace/products-prepare/linux/yc-image-cleanup.sh` (прочитано 2026-11-20). **AWS** — по памяти
(«вывод»), документации AWS Marketplace на GitHub нет, сайт aws.amazon.com с этой машины не читался.

## Yandex Cloud Marketplace (продукт для Compute, образ Linux)
| Требование | Где выполнено | Проверено / не проверено |
|---|---|---|
| Образ на Linux, virtio-драйверы (`virtio-net/blk/pci`) | Ubuntu 24.04 (ядро с virtio) | `check-image.sh`: virtio загружены — PASS в ВМ из образа |
| Серийная консоль `ttyS0` | базовый cloud image Ubuntu | PASS (`/proc/cmdline`) |
| DHCP, cloud-init с сервисом метаданных Yandex | cloud-init Ubuntu; источник данных определяется сам | не проверено на Yandex (нужен аккаунт); в qemu — NoCloud |
| SSH стартует сам, порт 22 открыт, **вход по паролю запрещён** | `cleanup.sh` убирает `50-cloud-init.conf` | **дефект найден и исправлен (итер. 780):** образ после Packer имел `PasswordAuthentication yes`; после правки в ВМ `sshd -T` → no, `yc-image-cleanup.sh -t` → все PASS (правка проверена правкой на живой ВМ, не пересборкой образа — 21 мин) |
| В образе нет готовых ключей хоста ssh, паролей | `cleanup.sh`: `ssh_host_*`, `authorized_keys`, `cloud-init clean`; пароль админа задаётся при первом запуске из user-data | `yc-image-cleanup.sh -t`: ключи/пары в `.ssh` — PASS; в запечённом выпуске нет `.env` — PASS |
| Очищены `/tmp`, `/var/tmp`, `/var/log`, кэши менеджера пакетов, `.bash_history`, аренды DHCP, `/etc/machine-id` | `cleanup.sh` (часть — `cloud-init clean --logs --machine-id`, `apt-get clean`, история и аренды — добавлено в 780) | `/tmp`, `/var/tmp`, `/var/log` целиком — **не проверено** (чистятся только журналы cloud-init и journald); `yc-image-cleanup.sh -c` на образе не запускался |
| Нет лишних системных пользователей, нет лишних прав в sudoers | пользователей добавляет только Packer (удаляется `shutdown_command`) | `check-image.sh` (sudoers) PASS; список пользователей — `yc-image-cleanup.sh -t` PASS |
| В `fstab` нет swap; диск по UUID, не шифрован | `cleanup.sh` (`sed` по swap); диск данных монтируется по UUID скриптом установки | PASS в ВМ |
| Сервисы переживают перезагрузку | `onprem.service` + `Restart=on-failure` | проверено перезагрузкой в Q4.8 (`ONPREM_CLOUD.md` §8) |
| Загрузочный диск: MBR (Gen 1.x) или GPT (Gen 2) | базовый образ Ubuntu — GPT+BIOS/EFI гибрид; поколение не выбиралось | **не проверено** (платформа Yandex) |
| Продукт: постоянное имя, тип, имя ru/en, доступ | `yandex/product.yaml` → `product` | заполнено; подача — вручную, не проверено |
| Версия: логотип SVG, категории, тариф, образ, описание/инструкция/поддержка/сценарии (ru+en), ссылки, условия, ПО, ресурсы ВМ | `yandex/product.yaml` → `version` | текстами заполнено; **TODO**: логотип, точные категории, тариф, контакт поддержки, опубликованный EULA, ссылки (в репозитории их нет) |
| Лицензионные условия, ПО третьих сторон | `LICENSE` (EULA вендора), список в `third_party_terms` | лицензии версий Postgres/Redis/Traefik/Telegraf не сверены |
| Модерация (технические специалисты и редакторы) | — | вне нашего контроля |

## AWS Marketplace (AMI) — по памяти, сверить с Seller Guide
| Требование | Где выполнено | Проверено / не проверено |
|---|---|---|
| AMI x86_64 HVM, ENA, сборка через `amazon-ebs` | `deploy/packer` (источник `amazon-ebs.onprem`) | только `packer validate`; сборки нет (нет аккаунта) |
| Нет паролей по умолчанию, ключей в образе, отключён вход по паролю | `cleanup.sh`, пароль — из user-data | как у Yandex; на AWS не запускалось |
| Нет облачных ключей и данных клиента в образе | `bake()` не трогает секреты (тест в `test_cloud_init.sh`) | тест проходит |
| IMDSv2 | модуль AWS (`http_tokens=required`) | `tofu test` (mock); образ с IMDSv2 не запускался |
| Листинг: название, описание, подсветки, категории, инструкции, EULA, поддержка, возврат, типы инстансов, порты | `aws/product.yaml` | заготовка; **TODO**: EULA, поддержка, возврат |
| Скан уязвимостей и проверка AMI самой площадкой (запрос на доступ `ec2:ModifyImageAttribute` для аккаунта Marketplace) | — | вне нашего контроля, не проверялось |
| Шаблон CloudFormation (рекомендуется площадкой) | нет, только Terraform | вне рамок |

## Как проверить образ
`sudo bash deploy/marketplace/check-image.sh /path/to/yc-image-cleanup.sh` — внутри ВМ, запущенной из собранного образа.
Итог в ВМ из образа Q4.9 (после правки sshd): 13 проверок PASS + `yc-image-cleanup.sh -t` PASS.
