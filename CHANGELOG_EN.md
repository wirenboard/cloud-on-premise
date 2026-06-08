# Changelog

All notable changes to this project are documented in this file.

## [2.0.0] - 2026-06-06

> **Breaking release.** See [`RELEASE_NOTES_2.0.md`](RELEASE_NOTES_2.0.md) for
> details and the upgrade procedure.

- **Email login** — email is now the login (mandatory and unique). Accounts with no
  email are repaired during the upgrade, without data loss.
- **Per-organization Grafana dashboards** (new `clients-grafana` service).
- **Metrics moved to TimescaleDB** (from InfluxDB), ingested via Telegraf over
  HTTPS+mTLS. Past history does not carry over into the new charts.
- **Daily PostgreSQL backups to S3** (MinIO).
- **Guided `make upgrade`** — mandatory backup → user-account check/repair →
  migration (see RELEASE_NOTES).
- pgcat pooler removed — the backend connects to PostgreSQL directly (single-node).
- Redis `6` → `7.4.8`.

## [1.3.0] - 2026-06-04

### Changed

- Metrics storage migrated from InfluxDB to TimescaleDB. Controller metrics are
  now ingested by a Telegraf service (HTTPS + mTLS, request rate limiting via
  Traefik) and written into TimescaleDB. The upstream HA layer (Patroni, etcd,
  HAProxy, pgBackRest) is not used for the single-node deployment — a single
  TimescaleDB instance runs instead.
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
