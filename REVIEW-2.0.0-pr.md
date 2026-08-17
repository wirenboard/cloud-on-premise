# Code review — релиз 2.0.0 (ветка `claude/pr-review-eb2e10`)

- **Дата ревью:** 2026-08-17
- **Диапазон:** `0b9cb3e` (merge-base с main) … `49d9483`, 73 коммита, 24 файла, +3002/−305
- **Метод:** 8 параллельных специализированных ревьюеров (security, stability, conventions, documentation, regressions, test coverage, simplification, architecture) + верификация находок по исходникам и upstream-репозиторию `cloud-infrastructure`

## Вердикт: Request changes

Критических блокеров нет, но несколько независимых предупреждений складываются в риск-паттерн для скриптов, выполняющихся на клиентских машинах: дыра в грантах метрик-БД, ломкий первый init TimescaleDB, тихая порча почтовой конфигурации при апгрейде и англоязычная документация с противоположными (опасными) советами по бэкапу и откату. Всё чинится точечно; архитектура изменений в целом добротная и хорошо прокомментированная.

**Первоочерёдное перед релизом:**
1. Гранты в `init.sql.tmpl` (REVOKE от PUBLIC) — **чинить upstream-first в cloud-infrastructure**, затем ре-синк.
2. SQL-экранирование паролей в `timescale/10-apply-init.sh`.
3. Ветка plain-smtp в `scripts/migrate-env.sh`.
4. `scripts/**` в release-ассеты (`make_release.yml`).
5. Очистка `/tmp/influx-backup` перед бэкапом в `scripts/upgrade.sh`.
6. Синхронизация README_EN — там сейчас опасные советы по бэкапу/откату.

---

## Critical

Нет.

## Warnings

### 1. [security] `REVOKE EXECUTE` — фактически no-op: SECURITY DEFINER-процедуры доступны reader-ролям
`timescale/init.sql.tmpl:441-442` · **унаследовано из прода** (`cloud-infrastructure/roles/deploy_stack/templates/timescale-init.sql.j2:659-660`)

PostgreSQL по умолчанию даёт EXECUTE роли PUBLIC; отзыв у `views_reader`/`all_reader` не трогает PUBLIC-грант. `ensure_measurement` и `auth.run_host_retention` (SECURITY DEFINER, строки 147/186/341) может вызвать любой, кто пишет SQL через Grafana-датасорс — цикл `CALL auth.run_host_retention()` это дешёвый CPU/IO DoS по всему hypertable. **Та же дыра прямо сейчас есть в продуктовом облаке** — нужен отдельный тикет на прод.

**Фикс:** `REVOKE EXECUTE ON ALL FUNCTIONS/PROCEDURES IN SCHEMA public, auth FROM PUBLIC` + `ALTER DEFAULT PRIVILEGES ... REVOKE ... FROM PUBLIC`, затем явные `GRANT`: `ensure_measurement` — телеграфу, `auth.is_admin()` / `allowed_orgs_from_roles()` — читателям (нужны для readable-views). Сначала PR в cloud-infrastructure (логика коммита `bc4ee08`: local-only hardening теряется при синке), потом сюда.

### 2. [stability] Пароль с `'` или `$$` ломает рендер init SQL; volume остаётся полу-инициализированным
`timescale/10-apply-init.sh:25-36` · **проблема переноса** (sed-шаблонизация вместо upstream Jinja2)

`esc()` экранирует только sed-спецсимволы (`\/&`) — коммит `0accc7f` закрыл sed, но не SQL-литералы. При падении psql initdb уже заполнил каталог данных: на рестарте entrypoint пропускает init-скрипты, TimescaleDB поднимается «здоровым», но без ролей telegraf/grafana, без `ensure_measurement` и retention. Ничто не перезапустит init, кроме сноса volume.

**Фикс:** `s/'/''/g` перед подстановкой (плюс отказ от `$$`-конфликтных значений) или передача креденшлов через `psql -v`.

### 3. [regressions] `EMAIL_PROTOCOL=smtp` (без шифрования) молча превращается в `EMAIL_USE_TLS=True`
`scripts/migrate-env.sh:81-85` · **проблема переноса**

Ветки только две: `*ssl*` → SSL, всё остальное → TLS. Инсталляции с внутренним релеем на 25 порту после апгрейда перестают отправлять письма; сбой ничем не сигнализируется (облако «молча не шлёт»).

**Фикс:** третья ветка — голый `smtp` без суффикса → `EMAIL_USE_TLS=False`; опционально печатать предупреждение.

### 4. [conventions] В release-ассеты не добавлен `scripts/**` (и `RELEASE_NOTES_2.0.md`)
`.github/workflows/make_release.yml` · **проблема переноса**

Workflow добавляет `timescale/**`, `telegraf/**`, `grafana/**`, `migration/**`, но Makefile из того же набора ассетов жёстко зависит от `scripts/fetch-geoip.sh` (каждый `make run`) и `scripts/upgrade.sh` (`upgrade`/`backup`/`fix-users`). Установка из ассетов релиза получает нерабочие основные цели. Приложенные CHANGELOG'и ссылаются на неприложенный `RELEASE_NOTES_2.0.md`.

**Фикс:** добавить `scripts/**` и `RELEASE_NOTES_2.0.md` в `files:`.

### 5. [stability] Бэкап InfluxDB может выдать устаревшие данные за свежие
`scripts/upgrade.sh:59-67` · **проблема переноса**

`influx backup` пишет в фиксированный `/tmp/influx-backup` долгоживущего контейнера, ошибки глотаются `|| true`. После любого прежнего запуска (`make backup`, повторный `make upgrade`) там лежат старые файлы — упавший бэкап проходит проверку на непустоту, скрипт печатает «backup written», оператор идёт в апгрейд с несвежей копией истории метрик.

**Фикс:** `docker exec "$cid" rm -rf /tmp/influx-backup` перед бэкапом; не глотать код возврата `influx backup` (хотя бы warning с реальной ошибкой).

### 6. [regressions] 1.x-сирота `worker-influx` продолжает работать во время миграции схемы
`scripts/upgrade.sh:201-203` · **проблема переноса**

`app_services` берётся из 2.x compose-файла — сироты (`influx`, `worker-influx`) не останавливаются. Celery-воркер 1.x разбирает очередь и держит соединения с PostgreSQL, пока идёт `manage.py migrate`: риск блокировок/дедлоков на DDL и записей по 1.x-схеме посреди миграции. Release notes упоминают сирот только как post-upgrade cleanup.

**Фикс:** после бэкапа явно стопить контейнеры compose-проекта, отсутствующие в `compose config --services` (influx оставить до конца бэкапа, воркеру причин жить нет).

### 7. [stability] Захардкоженное 16-дневное окно не применяет per-host retention в диапазоне ~17–30 дней
`timescale/init.sql.tmpl:369` · **проблема переноса** (запечённый рендер upstream-выражения)

Upstream вычисляет окно: `{{ timescale_max_host_retention_days + timescale_chunk_interval_days }}` (14+2=16 на стейджингах). При ручном коллапсе шаблона «16» запекли константой и одновременно подняли `TIMESCALE_MAX_HOST_RETENTION_DAYS` до 30. Итог: при `retention_days >= ~18` chunk впервые становится кандидатом на удаление, уже выпав из окна — данные живут до страховочного `drop_after` (+2 дня к максимуму). README при этом обещает, что снижение retention начинает удалять раньше. `RAISE NOTICE` выглядит как успешная работа джоба — разрыв невидим.

**Фикс:** вернуть вычисление — окно из `__RETENTION_SAFETY_DAYS__` (или `max(host retention) + chunk_interval`), не константа.

### 8. [stability] `GRAFANA_ADMIN_MANAGEMENT_URL` собирает URL из сырых креденшлов
`docker-compose.yml:43` · **унаследованный контракт** (`cloud-infrastructure/stacks/wbc.yml.j2:61`), **усилен переносом**

`GRAFANA_ADMIN_PASSWORD` — новая обязательная переменная, которую придумывает оператор (в проде пароль контролирует инфра). Символы `@:/#%` дают нераспарсиваемый URL — провижининг дашбордов/пользователей падает с невнятными ошибками, при этом сама Grafana стартует (получает пароль отдельно). Тот же класс ошибок, который этот релиз убрал вместе с `EMAIL_URL`.

**Фикс:** правильный — раздельные переменные в бэкенде; паллиатив — валидация charset в `make check-env` + предупреждение в `.env.example`.

### 9. [conventions/security] Креденшлы метрик-стора существуют только как слабые compose-дефолты
`docker-compose.yml:100-112` · **проблема переноса** (в проде пароли из vault)

`TIMESCALE_*`, `TELEGRAF_TIMESCALE_*`, `GRAFANA_TIMESCALE_*` нет ни в `.env.example`, ни в `REQUIRED_VARS` — инсталляции едут на паролях из публичного репозитория, хотя предшественники (`INFLUXDB_*`) были обязательными с генератором. Пароли запекаются в volume при первом init: оператор, выставивший их позже, молча ломает telegraf/grafana. Плюс дефолт `GRAFANA_TIMESCALE_PASSWORD` расходится между `10-apply-init.sh:17` (`grafana_db_password`) и compose (`grafana_timescale_password`).

**Фикс:** генерировать в `make generate-env` (эффективны только до первого init, который generate-env предшествует) или задокументировать по образцу `MINIO_ROOT_*`; выровнять дефолты в двух файлах.

### 10. [documentation] README_EN: «ручной бэкап не нужен» — неверно и противоречит RU
`README_EN.md:613-616` · **проблема переноса**

`make fix-users` в любом режиме кроме `scan` правит живую базу **до** автоматического бэкапа (тот делается позже, внутри `make upgrade`); прежние пары логин/почта нигде не сохраняются. RU-README явно требует `make backup` заранее; EN говорит обратное — цена ошибки: невосстановимые данные аккаунтов.

**Фикс:** отзеркалить RU-формулировку.

### 11. [documentation] README_EN: совет отката «restore the database from that dump and retry» опасен
`README_EN.md:692-694` · **проблема переноса**

RU-процедура прямо запрещает повторный запуск на этом checkout (часть миграций уже применена) и требует полного отката по RELEASE_NOTES: down 2.x-стека на старом теге, старейший `.env.bak-*`, пересоздание БД, restore. EN-оператор получает материально более опасную инструкцию.

**Фикс:** заменить на перевод RU-текста.

### 12. [documentation] Русский security-док противоречит коду в двух местах
`doc/SECURITY_NETWORK.md:58, :134` (+ EN-пара для второго пункта) · **проблема переноса**

Wildcard `*.apps` назван «опциональным», хотя он в `REQUIRED_DOMAINS` и без него `make check-certs` валит запуск. Легенда диаграммы всё ещё говорит «EMAIL_ENABLED=True (по умолчанию включена)», хотя переменная стала обязательной с fail-fast в compose.

**Фикс:** убрать «опциональный» (запись DNS и SAN обязательны, «используется по требованию»); легенды — «только при явном EMAIL_ENABLED=True (переменная обязательна с 2.0)».

### 13. [documentation] RELEASE_NOTES_2.0.md только на русском, но EN-доки ссылаются на него как на основную процедуру
`RELEASE_NOTES_2.0.md` · **проблема переноса**

Ломает парную RU/EN-конвенцию репо (README/README_EN и т.д.). Полный rollback, `CONFIRM=yes` для headless-запуска и предупреждение «определитесь с METRICS_RETENTION_DAYS до апгрейда» существуют только по-русски, при этом `CHANGELOG_EN.md` и `README_EN.md` шлют англоязычного оператора именно сюда.

**Фикс:** `RELEASE_NOTES_2.0_EN.md` или как минимум перенести rollback и `CONFIRM=yes` в EN-README.

### 14. [regressions] Подсказка `check-env` уводит 1.x-операторов в обход `make upgrade`
`Makefile:204-209` · **проблема переноса**

Привычный `git pull && make update` падает на check-env; оператор по новой подсказке докопирует переменные из `.env.example` — и `make update` едет в авто-миграцию на непочиненной 1.x-базе: без бэкапа, без гейта аккаунтов, миграция 0013 падает посреди последовательности.

**Фикс:** детектировать 1.x-сигнатуру (`INFLUXDB_TOKEN`/`ADMIN_USERNAME` в .env) и печатать «обновляетесь с 1.x? — `make upgrade`, не правьте .env руками».

### 15. [test coverage] Ключевая мутационная логика без тестов
`migration/migration_doctor.py`, `scripts/migrate-env.sh` · **проблема переноса** (в репо нет тестовой инфраструктуры вообще)

- `migration_doctor.py` — 443 строки ветвистой логики, необратимо переписывающей username/email на клиентских базах. Чистая часть (детектор, decision-table `auto_fix`, `_resolve_argv`) отделима от ORM и тестируема без Django.
- `migrate-env.sh` — чистое преобразование текста: фикстурный 1.x `.env` на входе, построчный assert на выходе, повторный прогон на идемпотентность и семантику маркера `# <<< FILL IN`. Самый дешёвый и ценный тест изменения — и он поймал бы баг №3.

---

## Suggestions

1. **[security]** `readTimeout=3600s` навешан на весь публичный entrypoint 443 (`traefik/traefik.toml:4-6`) — slowloris-окно с 60 с до часа для всех роутеров. Отдельный entrypoint для туннельных аплоадов или снизить до реального потолка (350 MB файлменеджера).
2. **[security]** `conflicts.yaml` делается world-writable 0666, `apply` слепо доверяет содержимому (`migration_doctor.py:330-336`) — локальный пользователь хоста в окне dump→apply может подменить `new_email` админа. Достаточно 0644.
3. **[stability]** `redis-server --save "" --appendonly no` (`docker-compose.yml:131`) теряет очереди Celery при любом рестарте: письма-приглашения ничем не переотправляются. Вернуть RDB-снапшоты или зафиксировать trade-off комментарием.
4. **[stability]** Grafana SMTP пинит `MandatoryStartTLS`, игнорируя `EMAIL_USE_SSL` (`grafana/clients-grafana.ini:66-74`, конфиг on-prem-авторский). Прогнать алерт-письмо на 465/SSL-инсталляции до релиза.
5. **[regressions]** Fallback `fix_users` на остановленном стеке и re-check после stop идут на образе 2.0 (`upgrade.sh:91-95`): если entrypoint образа мигрирует при старте, `compose run` сам запустит миграцию, которую гейт должен был удержать. Проверить entrypoint (вне этого репо) или добавить `--entrypoint`-override.
6. **[conventions]** `GEOIP_ENABLED` понимает только `true|on|yes|1` (`fetch-geoip.sh:19`), а новый check-env канонизирует `+ ok|y`: `GEOIP_ENABLED=y` молча выключает геолокацию. Выровнять словари.
7. **[simplification]** Дубли: одинаковые ветки `if __name__ ... else` (`migration_doctor.py:439-443`); эпилог «detect→print→exit» скопирован в 5 режимов `main()`; трижды-экранированная команда доктора повторена в `upgrade.sh:78` и `:93`; healthcheck бэкенда скопирован в `tunnel-webhooks-backend` вместо YAML-anchor.
8. **[documentation]** Один EN-resync-проход: docstring доктора показывает форму запуска `-- <args>`, которую `upgrade.sh` называет нерабочей; EN-комментарий к `METRICS_RETENTION_DAYS` приглашает поднять значение, что ниже объявлено невозможным; EN-раздел апгрейда отстаёт от RU на 5+ операционных деталей (caveat про ADMIN_EMAIL из окружения работающего контейнера, `--remove-orphans`, семантика `.env.bak-*`, auto-фиксы в `dump`/`resolve`, prerequisite `git pull`).
9. **[test coverage]** Для `backup()` — задокументированная пред-релизная репетиция на одноразовом 1.5.0-стенде (`make backup`: непустой pg-дамп + influx-каталог).

---

## Architecture & design (forward-looking, non-blocking)

1. **Парсинг .env и булевы словари размножены по 4 местам** (Makefile, fetch-geoip, migrate-env, upgrade.sh) с уже случившимся дрейфом (`y`/`ok`, отсутствие lowercase в `env_value` upgrade.sh).
   - *A — общий `scripts/lib.sh`* (s): одно определение; минус — скрипты не самодостаточны, Makefile всё равно отдельно.
   - *B — минимум: выровнять словари, дубли оставить* (s): ноль риска перед релизом; минус — дрейф вернётся.
   - **Рекомендация:** B сейчас, A после 2.0.0 (upgrade-скрипты временные — «delete once 1.x is out of support»).
2. **Rate-limit-константы синхронизированы комментарием** между env бэкенда (`docker-compose.yml:38-40`) и Traefik-лейблами telegraf (:164-166). YAML-anchors для 2 из 3 значений — пятистрочный фикс в духе существующих `x-*`; либо оставить как есть.
3. **`init.sql.tmpl` — ручной форк j2-шаблона из cloud-infrastructure** с security-чувствительным SQL, уже потребовавший один ре-синк. Минимум: вписать в шапку commit hash upstream-ревизии, чтобы следующий ре-синк был механическим diff'ом. Генерация из upstream CI — избыточно при текущей частоте изменений.

---

## Происхождение проблем: перенос vs продуктовое облако

| # | Находка | Происхождение |
|---|---------|---------------|
| W1 | REVOKE EXECUTE no-op | **Прод** (j2:659-660, дыра есть и в облаке — тикет на прод, фикс upstream-first) |
| W2 | esc() без SQL-кавычек | Перенос (sed вместо Jinja2) |
| W3 | plain-smtp → TLS | Перенос |
| W4 | Release-ассеты без scripts/** | Перенос |
| W5 | Stale influx-бэкап | Перенос |
| W6 | worker-influx при миграции | Перенос |
| W7 | Окно «16 дней» | Перенос (запечённый рендер upstream-выражения `max_retention + chunk_interval`) |
| W8 | Креденшлы в GRAFANA_ADMIN_MANAGEMENT_URL | Контракт из прода (wbc.yml.j2:61), риск усилен переносом |
| W9 | Слабые дефолты TIMESCALE_* | Перенос (в проде vault) |
| W10–13 | Документация (EN/RU расхождения, RELEASE_NOTES) | Перенос |
| W14 | Подсказка check-env | Перенос |
| W15 | Тесты | Перенос |
| — | Первопричина migration_doctor (миграция users/0013 без data migration) | **Прод** (cloud-backend); сам доктор — локальная компенсация |
| — | Rate-limit значения | Контракт прода; sync-by-comment — перенос |

---

*Ревью: 8 специализированных агентов + judge-pass с верификацией по исходникам ветки и upstream cloud-infrastructure. Plan-compliance и project-rules не запускались (нет `docs/*_plan.md` и `project-rules.md`).*

---

## Статус закрытия (2026-08-17)

Ветка на момент проверки: `42eb7a2`, PR wirenboard/cloud-on-premise#30.

**Закрыто в этом релизе:**

| # | Находка | Где |
|---|---------|-----|
| W2 | SQL-кавычки в `esc()` | 36b2902 |
| W3 | plain-smtp → `EMAIL_USE_TLS=False` | 0010558 |
| W4 | `scripts/**` + `RELEASE_NOTES_2.0.md` в ассетах | 1f30e90 |
| W5 | очистка `/tmp/influx-backup` перед бэкапом | 0010558 |
| W6 | остановка сирот 1.x после бэкапа | 0010558 |
| W7 | окно retention из `__RETENTION_SAFETY_DAYS__` | 36b2902 |
| W9 | выровнен дефолт `grafana_timescale_password` (частично: генерация отложена) | 36b2902 |
| W10–W12 | README_EN и security-доки приведены к RU | 42eb7a2 |
| W14 | `check-env` распознаёт 1.x `.env` | 0010558 |
| S2 | `conflicts.yaml` 0644 | 09a65d2 |

**Вынесено upstream-first** (локальная правка потерялась бы при ре-синке):

- W1 (EXECUTE у PUBLIC) и `search_path` у `ensure_measurement` → черновик wirenboard/cloud-infrastructure#232. Наш `init.sql.tmpl` получит это ре-синком после решения коллег; локальный пин был откачен в `bc4ee08` намеренно.

**Отложено осознанно, не блокирует релиз:** W8 (валидация пароля Grafana в URL — правильный фикс в бэкенде), W9 в части генерации паролей метрик-стора, W13 (EN-версия RELEASE_NOTES; откат и `CONFIRM=yes` перенесены в README_EN), W15 (тесты — нет тестовой инфраструктуры), S1, S3, S4, S6, S7.

**Опровергнуто проверкой:** S5 — fallback `fix_users` на остановленном стеке миграцию не запускает (прогон гонки: после отказа гейта в базе осталось 137 миграций, entrypoint образа не мигрирует).
