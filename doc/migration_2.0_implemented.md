# On-Premise 1.x → 2.0 — что сделано для миграции

**Статус:** реализовано, не протестировано на живой БД · **Дата:** 2026-06-06
**Ветка:** `release/2.0.0` (локально, не запушена) · **VERSION:** `2.0.0`

Документ описывает, **что фактически собрано** для перехода on-premise 1.x → 2.0.
Проектное обоснование — в [`upgrade_2.0_plan.md`](upgrade_2.0_plan.md); здесь —
реализация.

---

## Что решает миграция

Upstream-миграция `cloud-backend` `users/0013_alter_user_options_alter_user_email_and_more`
делает `email` уникальным и добавляет `CheckConstraint(username == email)` **без
переноса данных**. На заполненной базе 1.x она падает и откатывается:

- админ on-premise создаётся как `username="admin"`, `email=""` (дефолт 1.x
  `ADMIN_EMAIL=""`) → нарушает `username == email`;
- любые пустые / дублирующиеся / несовпадающие email ломают шаги `unique` / `check`.

Upstream ремонтной миграции нет — чиним данные на стороне on-premise **до** `migrate`.
**Данные пользователей не выбрасываются**, приводятся в порядок на месте.

---

## Реализация по компонентам

### 1. `migration/migration_doctor.py` (новый, ~440 строк)

Детектор + ремонтник таблицы пользователей. Один детектор и один валидатор на все
режимы; идемпотентен; выходит с ненулевым кодом, пока остаётся хоть один конфликт
(это и есть гейт для `make upgrade`).

- **Запуск:** внутри ещё работающего контейнера бэкенда 1.x (он стартует без новых
  TimescaleDB-переменных), через Django ORM по модели пользователя — обходит проблему
  бутстрапа нового образа. Затрагивает **только** `username` / `email`. Работает и на
  образе 1.x, и на 2.0.
- **Детектируемые конфликты:** `blank` (пустой/NULL email), `mismatch`
  (`username != email`, сравнение точное — любое различие, включая регистр/пробелы),
  `dup` (email повторяется без учёта регистра).
- **Режимы CLI:** `scan` (только чтение, таблица + счётчики), `auto` (только безопасные
  авто-исправления), `resolve` (auto + интерактивный мастер на TTY), `dump [FILE]`
  (auto + выгрузка остатка в `conflicts.yaml`), `apply [FILE]` (применить отредактированный
  файл обратно).
- **Безопасные авто-исправления (`auto`):** (1) пустой email админа, когда `ADMIN_EMAIL`
  задан, валиден и свободен → `username = email = ADMIN_EMAIL`; (2) email и username
  отличаются только регистром/пробелами → канонизация к нормализованному email (потери
  данных и новой коллизии быть не может). Пустые email без `ADMIN_EMAIL`, реальные
  несовпадения и настоящие дубликаты **намеренно** оставлены человеку.
- **Валидация в каждом режиме:** корректность email + отсутствие коллизии с другим
  пользователем перед записью. `normalize()` = trim + lowercase, зеркалит
  `app.utils.normalize_email` в backend.

### 2. `Makefile` — оркестрация (новые цели)

- **`make upgrade`** — единая команда 1.x → 2.0:
  `generate-env` → `check-certs` → **(1) обязательный `make backup`** → **(2) `fix-users
  MODE=scan`** → **(3) ГЕЙТ:** при конфликтах `exit 1`, печать команд исправления, миграция
  НЕ запускается → **(4)** `docker compose pull` + `migrate` на образе 2.0 → **(5)**
  поднятие стека.
- **`make fix-users MODE=…`** — обёртка над `migration_doctor`; монтирует `./migration`
  в контейнер, использует `exec` если backend уже запущен, иначе `run --rm`.
- **`make backup`** — отдельный бэкап: `pg_dump | gzip` → `backups/pg-<ts>.sql.gz`
  (с проверкой непустоты — пустой дамп прерывает процесс) + `influxd backup` →
  `backups/influx-<ts>/`, только если сервис `influxdb` ещё запущен.

### 3. Метрики: бэкап InfluxDB, без конвертации

InfluxDB → TimescaleDB **не конвертируется** (дорого/хрупко). При переходе делается
`influxd backup`, копия остаётся рядом для оператора. Новые метрики копятся в
TimescaleDB. Зафиксировано в CHANGELOG и README.

### 4. Grafana → встроенная SQLite

Внутренняя конфигурационная БД Grafana (дашборды/пользователи/организации) переведена
с внешнего Postgres/pgcat на `sqlite3` (`grafana/clients-grafana.ini`:
`type = sqlite3`, `path` в `/var/lib/grafana`, том `clientsGrafanaData` уже персистит).
Удалено: `postgres/init-grafana-db.sh`, grafana-пул в `pgcat/pgcat.toml`, переменные
`GRAFANA_DB_*`. **TimescaleDB сохранён как datasource** Grafana (`GRAFANA_TIMESCALE_*`) —
это хранилище метрик, не трогается.

### 5. Compose / окружение (сведено с upstream `main`)

`docker-compose.yml`, `.env.example`, `pgcat/pgcat.toml`, `telegraf/telegraf.conf`,
`timescale/init.sql.tmpl` + `timescale/10-apply-init.sh`:

- backend: обязательные TimescaleDB-переменные, Celery-очереди (`metrics_queue`,
  `grafana_queue`, `email_queue`, `default_queue`), InfluxDB убран из требований;
- tunnel: JWT-ключ теперь **смонтированный keyfile** + `BACKEND_APP_PUBLIC_KEY_PATH`
  (env с PEM-содержимым удалён);
- webssh: `REDIS_URL` для токенов SFTP-загрузки (Redis уже в compose);
- frontend: lockstep с backend, без состояния/миграции.

### 6. Версия и документация

`VERSION` → `2.0.0`; `CHANGELOG.md` / `CHANGELOG_EN.md` (несовместимые изменения,
обязательный бэкап, email-как-логин, конфликт-резолвинг, InfluxDB-бэкап, Grafana→SQLite,
новые сервисы/env); раздел «Обновление 1.x → 2.0» в `README.md` / `README_EN.md`.

---

## Гарантии безопасности данных

- **Бэкап обязателен и идёт ПЕРВЫМ** — до любого изменения БД. Пустой pg-дамп прерывает
  апгрейд.
- **Гейт не пропускает грязные данные** — `migrate` не запустится, пока `scan` не вернёт
  `Conflicts: 0`.
- **Идемпотентность** — `fix-users` и весь `upgrade` можно перезапускать.
- **`./backups/pg-<ts>.sql.gz`** — точка отката: при сбое миграции восстановить из дампа
  и повторить.

---

## Допущения и границы

- **`license_service` НЕ добавлен.** Backend при `IS_ON_PREMISE` хардкодит
  `INTERNAL_LICENSE_SERVICE_TOKEN=""`, в cloud-infrastructure такого сервиса нет. Добавлять
  неконфигурированный сервис рискованнее, чем не добавлять. Если on-premise-лицензирование
  всё же потребуется — это отдельная задача.
- **`migration_doctor` живёт только в on-premise** — никакого upstream-PR в `cloud-backend`.
- Реалистичный масштаб конфликтов: админ + <10 безэмейльных пользователей, редкие дубли —
  достаточно мало для консольного мастера. Пустые email требуют человека by design.

## Что НЕ протестировано (нет заполненной БД / реальных образов 2.0)

- реальный прогон `migrate` на образе 2.0;
- `migration_doctor` в реальном контейнере backend;
- интерактивный мастер на живом TTY;
- полный старт стека 2.0.

Проверено статически: `py_compile`, логика детектора на заглушках, `docker compose config`,
`make -n upgrade`.

---

## Файлы (ветка `release/2.0.0`, 4 коммита поверх `sync/upstream-parity`)

| Файл | Изменение |
|---|---|
| `migration/migration_doctor.py` | новый — детектор + ремонтник |
| `Makefile` | `upgrade`, `fix-users`, `backup` |
| `docker-compose.yml` | TimescaleDB/Celery/tunnel keyfile/webssh redis |
| `grafana/clients-grafana.ini` | внутренняя БД → SQLite |
| `pgcat/pgcat.toml` | удалён grafana-пул |
| `timescale/init.sql.tmpl`, `timescale/10-apply-init.sh` | инициализация TimescaleDB |
| `telegraf/telegraf.conf` | вывод метрик в TimescaleDB |
| `.env.example`, `.gitignore` | новые переменные; `backups/`, `conflicts.yaml` |
| `VERSION` | `2.0.0` |
| `CHANGELOG.md`, `CHANGELOG_EN.md`, `README.md`, `README_EN.md` | документация |
| `postgres/init-grafana-db.sh` | удалён |
