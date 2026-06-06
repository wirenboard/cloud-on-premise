# Changelog

All notable changes to this project are documented in this file.

## [2.0.0] - 2026-06-06

> **Breaking release.** User data is **not** discarded — it is migrated in place.
> Upgrade with `make upgrade`, which makes a **mandatory backup first** and will
> **refuse to migrate** until all user-account conflicts are resolved.

### Breaking

- A user's **email is now the login**: it is mandatory, unique
  (case-insensitive), and must equal the username. The upstream migration that
  enforces this (`users/0013`) has no data backfill, so a populated 1.x database
  must be repaired before migrating (see below).
- Removed the registration endpoint `/users-sign-up/` (replaced upstream by
  `/users/registrations/`); the bundled frontend is upgraded in lockstep.

### Added

- **`make upgrade`** — guided 1.x → 2.0 upgrade. Flow: mandatory backup
  (`pg_dump` + `influxd backup`, before any DB-mutating step) → scan the user
  table for conflicts → **stop and print the fix command if any remain** →
  `migrate` → bring up the 2.0 stack.
- **`migration_doctor`** (`migration/migration_doctor.py`) + **`make fix-users`**.
  Detects rows violating the 2.0 invariants (blank/NULL email, `username != email`,
  duplicate email) and repairs them. Safe cases are auto-fixed (lowercase email;
  collapse case/whitespace-only differences; admin email from `ADMIN_EMAIL`).
  The rest are resolved either through an **interactive wizard** or a headless
  **`conflicts.yaml`** edit-and-apply flow, both validated (valid email, no new
  collision). Idempotent; re-run until 0 conflicts.
- **`make backup`** — standalone PostgreSQL + InfluxDB backup into `./backups`.

### Changed

- **Grafana's internal config DB** (dashboards/users/orgs) moved from the
  external Postgres/pgcat pool to **built-in SQLite** under `/var/lib/grafana`
  (persisted on the `clientsGrafanaData` volume). TimescaleDB remains Grafana's
  metrics **datasource**, unchanged.
- **Tunnel authorizer** now reads the backend JWT public key from a **mounted
  keyfile** (`BACKEND_APP_PUBLIC_KEY_PATH`) instead of a PEM-in-env-var.

### Removed

- Grafana's external state database: `postgres/init-grafana-db.sh`, the pgcat
  grafana pool, and the `GRAFANA_DB_NAME` / `GRAFANA_DB_USER` /
  `GRAFANA_DB_PASSWORD` variables. The metrics-datasource role vars are now
  `GRAFANA_TIMESCALE_USER` / `GRAFANA_TIMESCALE_PASSWORD`.
- The `BACKEND_APP_PUBLIC_KEY` (PEM-content) env on the tunnel authorizer.

### Metrics history

- The InfluxDB → TimescaleDB store change is **not** auto-converted. On upgrade
  the existing InfluxDB database is **backed up and kept** alongside the
  deployment; new metrics accumulate in TimescaleDB. Restore/consult the backup
  later if you need the historical data.

## [1.3.0] - 2026-06-04

### Changed

- Metrics storage migrated from InfluxDB to TimescaleDB. Controller metrics are
  now ingested by a Telegraf service (HTTPS + mTLS, request rate limiting via
  Traefik) and written into TimescaleDB. The upstream HA layer (Patroni, etcd,
  HAProxy, pgBackRest) is not used for the single-node deployment — a single
  TimescaleDB instance runs instead.
- The backend now reaches the main PostgreSQL database through the pgcat
  connection pooler.
- Celery workers split by queue: `worker` (default), `worker-metrics`,
  `worker-grafana`, `worker-email`.
- Image bumps: Redis `6-alpine` → `7.4.8-alpine`.

### Added

- `clients-grafana` service (Grafana 12.2.2) — per-organisation dashboards;
  keeps its state in a dedicated database on the bundled PostgreSQL.
- `tunnel-webhooks-backend` service — a separate backend instance handling FRP
  tunnel webhooks.
- `postgres-backup` service — nightly PostgreSQL backup into the bundled MinIO
  (S3).
- New environment variables: `TIMESCALE_*`, `TELEGRAF_TIMESCALE_*`,
  `GRAFANA_DB_*`, `GRAFANA_ADMIN_*`, `METRICS_COLLECTOR_RATELIMIT_*`,
  `INTERNAL_LICENSE_SERVICE_TOKEN`, `CELERY_*_QUEUE`, `POSTGRES_BACKUP_*`, and
  optional external Prometheus integration (`PROM_*`).

### Removed

- The InfluxDB service and the related `INFLUXDB_USERNAME`, `INFLUXDB_PASSWORD`,
  `INFLUXDB_TOKEN` variables.

## [1.2.0] - 2026-05-29

### Added

- Customizable organization invitation email via environment variables.

### Fixed

- Incorrect browser language detection.

## [1.1.1] - 2026-05-27

### Added

- Localized organization invitation emails: English-speaking recipients now receive the invitation email in English (selected via the `Accept-Language` header).

## [1.1.0] - 2026-04-17

### Added

- Added the ability to override frontend assets: the page logo, favicon, and the icons used in browser tabs.

## [1.0.0] - 2026-01-17

### Added

- First stable release.

## [0.6.1] - 2025-08-14

### Changed

- Minor fixes and stability improvements.

## [0.6.0] - 2025-08-01

### Added

- First public release.

### Changed

- Updated the On-Premise section in the admin panel.
- Added a subsection with license and limit information.
- Improved the metrics subsection and its visual presentation.
- Fixed the `Invalid instance_uid` error.
- Applied other minor fixes.
