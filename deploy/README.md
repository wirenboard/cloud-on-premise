# On-Premise в публичном облаке: Yandex Cloud, Selectel, AWS

Здесь лежит всё, чтобы поднять Wiren Board Cloud On-Premise на своей ВМ в публичном облаке, не настраивая сервер руками:
Terraform/OpenTofu создаёт ВМ, отдельный диск под данные, сеть, правила доступа, статический IP и DNS-записи, а cloud-init
при первой загрузке ставит Docker, берёт выпуск on-premise, пишет `.env`, получает сертификат Let's Encrypt и запускает сервисы.

| Каталог | Что внутри |
|---|---|
| `terraform/examples/{yandex,selectel,aws}/` | то, что запускаете вы: пример конфигурации и `terraform.tfvars.example` |
| `terraform/modules/{yandex,selectel,aws}/` | модули облаков; `modules/user-data/` — общий cloud-init |
| `cloud-init/` | `install-onprem.sh` (установка, повторный запуск безопасен) и шаблон user-data |
| `packer/`, `marketplace/` | образ ВМ с предзагруженным выпуском и заготовки карточек для маркетплейсов |
| `tests/` | проверки без облачного аккаунта (`test_cloud_init.sh`, `tofu test` в каждом модуле) |

## Что понадобится

- [OpenTofu](https://opentofu.org) ≥ 1.6 или Terraform ≥ 1.6 (ниже — `tofu`; с Terraform команды те же: `terraform init`/`apply`).
- Аккаунт в облаке и права создавать ВМ, сеть, IP, DNS-зону (для AWS — ещё IAM-роль).
- Домен (поддомен) под облако, например `cloud.example.com`, который **заранее делегирован** на DNS облака — см. таблицу ниже.
  Сертификат запрашивается сразу при первой загрузке ВМ через DNS-01, и если делегирования ещё нет, установка остановится на шаге
  сертификата (как это исправить — «Если что-то пошло не так»).
- Ваш SSH-ключ и, по желанию, адреса, с которых разрешить SSH (`admin_cidrs`). Без `admin_cidrs` порт 22 закрыт для всех.

| Облако | Куда делегировать домен | Доступ для `tofu` |
|---|---|---|
| Yandex Cloud | NS `ns1.yandexcloud.net`, `ns2.yandexcloud.net` | `export YC_TOKEN=$(yc iam create-token)` (или `token` в tfvars) |
| Selectel | NS `a.ns.selectel.ru` … `d.ns.selectel.ru` | пользователь и пароль в tfvars; сервисный пользователь для DNS — в `acme_dns_credentials` |
| AWS | существующая зона Route53 (`hosted_zone_id`) — рекомендуется; иначе двухшаговый запуск ниже | `export AWS_PROFILE=…` (ключи в файлы не пишутся) |

## Три команды

```bash
git clone https://github.com/wirenboard/cloud-on-premise.git && cd cloud-on-premise/deploy/terraform/examples/yandex   # или selectel, aws
cp terraform.tfvars.example terraform.tfvars && nano terraform.tfvars                                                  # домен, пароль, ключ, адреса
tofu init && tofu apply
```

`tofu apply` покажет план и спросит подтверждение. После него ВМ ставит on-premise сама: **около 20 минут**, почти всё время —
скачивание образов контейнеров (в проверке на вложенной ВМ 4 ядра/6 ГБ — 1069–1100 с). Потом откройте адрес из вывода `url`
и войдите `admin_email` / `admin_password`.

**AWS без готовой зоны Route53.** Серверы имён новой зоны становятся известны только после её создания, поэтому сначала создайте
зону, делегируйте домен на `name_servers` из вывода и только потом всё остальное:

```bash
tofu apply -target=module.onprem.aws_route53_zone.this   # создаёт только зону, выводит name_servers
# пропишите эти NS у регистратора родительского домена, дождитесь: dig NS cloud.example.com
tofu apply
```

## Что создаётся

| | Yandex Cloud | Selectel | AWS |
|---|---|---|---|
| ВМ по умолчанию | `standard-v3`, 4 ядра, 8 ГБ | `SL1.4-8192` (4 ядра, 8 ГБ) | `m6i.xlarge` (4 ядра, 16 ГБ), IMDSv2 |
| Системный диск / данные | 30 ГБ / 100 ГБ network-ssd | том из Ubuntu 24.04 / 100 ГБ `fast` | gp3 30 ГБ / gp3 100 ГБ, шифрование |
| Сеть | VPC, подсеть, статический IP | сеть, роутер, плавающий IP | VPC или существующая подсеть, Elastic IP |
| DNS | зона + 5 A-записей | зона + 5 A-записей | 5 A-записей в зоне (новой или `hosted_zone_id`) |
| Сертификат | lego `yandexcloud`, токен сервисного аккаунта ВМ | lego `selectelv2`, ключи из `acme_dns_credentials` | lego `route53`, роль ВМ только на эту зону |

Пять A-записей: `домен`, `*.домен`, `*.ssh.домен`, `*.http.домен`, `*.apps.домен` — как в основном README («DNS-записи»);
`agent.домен`, `tunnel.домен`, `metrics.домен` покрываются `*.домен`. Размеры меняются переменными модуля: `boot_disk_gb`, `data_disk_gb` и
`cores`/`memory_gb` (Yandex), `flavor_name` (Selectel), `instance_type` (AWS) — см. `modules/<облако>/variables.tf`.

Открытые порты: **443** и **7107** (туннели контроллеров) — всем; **22** и **7501** (дашборд туннелей, по умолчанию выключен,
`enable_tunnel_dashboard`) — только с `admin_cidrs`. Почта по умолчанию выключена (`email_enabled`).

Данные (БД, файлы, образы Docker) лежат на отдельном диске `/data`; при перезагрузке ВМ сервисы поднимаются сами (`onprem.service`).
Сертификат продлевается таймером `onprem-cert-renew.timer` раз в неделю (если до конца осталось < 30 дней).

## Подключить контроллер

На контроллере (агент новее 1.5.14):

```bash
wb-cloud-agent use-on-premise https://cloud.example.com
```

и пройдите по активационной ссылке — подробно в основном README, раздел «Настройка контроллера». Контроллер ходит на
`agent.cloud.example.com` и `tunnel.cloud.example.com` — их даёт запись `*.домен`.

## Если что-то пошло не так

Зайдите по SSH (`ssh ubuntu@<public_ip>` — Yandex и AWS; на Selectel — тот же пользователь `ubuntu` образа; нужен ваш адрес в `admin_cidrs`):

```bash
cloud-init status --long                 # done / error
sudo tail -50 /var/log/onprem-install.log
cd /data/cloud-on-premise && sudo docker compose ps     # каталог установки (INSTALL_DIR)
```

Установка прервалась (чаще всего — сертификат: домен ещё не делегирован)? Исправьте причину и запустите установку ещё раз —
сделанные шаги она пропустит:

```bash
sudo /usr/local/sbin/install-onprem.sh
```

## Безопасность — что важно знать

- Пароль администратора и прочие значения из tfvars попадают в **метаданные ВМ** (user-data) и в **состояние** `terraform.tfstate`.
  Храните состояние как секрет (или в защищённом бэкенде), смените пароль администратора после первого входа.
  На AWS метаданные доступны только по IMDSv2 и с самой ВМ.
- Ключи AWS в ВМ не передаются: сертификат получает роль ВМ с правами только на свою зону Route53.
  На Selectel ключи сервисного пользователя DNS лежат на ВМ в `/etc/onprem/acme.env` (0600) — дайте ему только права на DNS.
- `tofu destroy` удаляет и **диск с данными**. Перед удалением сделайте бэкап (`sudo make backup` в `/data/cloud-on-premise`).

## Образ и маркетплейсы

`packer/onprem.pkr.hcl` собирает образ Ubuntu 24.04 с Docker, lego и предзагруженными образами выпуска (источники `qemu`,
`yandex`, `amazon-ebs`); первая загрузка из такого образа берёт тот же user-data и не скачивает образы. Карточки и требования
площадок — `marketplace/` (`REQUIREMENTS.md`, `check-image.sh` проверяет ВМ из образа).

## Что проверено и что нет

Проверено без облачного аккаунта: `tofu validate`, `tflint`, `tofu test` с подменёнными провайдерами (правила доступа, размеры,
DNS-записи, содержимое user-data) по всем трём облакам; установка с нуля по-настоящему — во вложенной ВМ Ubuntu 24.04 тем самым
user-data, который рендерит модуль Yandex, включая перезагрузку и подключение настоящего контроллера; сборка образа Packer `qemu`
и запуск ВМ из него.

**Не проверено** (нужен аккаунт): создание ресурсов в самих облаках (`tofu plan` с фиктивными ключами доходит до первого
запроса к API и получает отказ авторизации), получение сертификата Let's Encrypt через DNS облака, имена образов/типов ВМ/дисков
в конкретных зонах, сборки Packer `yandex` и `amazon-ebs`, публикация на маркетплейсах.
