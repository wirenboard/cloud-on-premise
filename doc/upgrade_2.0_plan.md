# Wiren Board Cloud On-Premise — 2.0 Upgrade Plan (1.x → 2.0)

**Status:** design locked, implementation pending
**Date:** 2026-06-06

## Decision

Upgrade from on-premise **1.2.0** to current upstream is a **MAJOR 2.0** release.
It breaks compatibility — **but user data is NOT discarded**. Existing data is
migrated in place; the operator never re-deploys from scratch.

### Why 2.0 (not a 1.3 point release)

`onprem-release/1.2.0` of `cloud-backend` is effectively `1.1.1` (Sep 2025) plus a
single cherry-picked commit. All of 2026's backend work lives only on `main`. The
delta is ~8 months: **343 files, 19 new migrations across 5 apps**, the metrics
backend swapped **InfluxDB → TimescaleDB**, new required services
(TimescaleDB, `license_service`, Grafana app), removed endpoints
(`/users-sign-up/` → `/users/registrations/`), and the user `email` became
**unique + the login + mandatory + the primary registration identifier**.

## The hard blocker

`cloud-backend` migration **`users/0013_alter_user_options_alter_user_email_and_more.py`**
adds `unique=True` on `email` and a `CheckConstraint(username == email)` — with
**no data migration / backfill / dedup**. On a populated 1.2.0 DB this fails:

- The on-premise admin is created with `username="admin"`, `email=""`
  (1.2.0 default `ADMIN_EMAIL=""`) → violates `username == email` → `migrate`
  aborts and rolls back.
- Any duplicate or blank emails also break the `unique` step.

There is no upstream repair migration. We supply the fix on the on-premise side.

## Mechanism: `make upgrade`

Idempotent, safe, fail-loud. The operator runs one command, sees conflicts in the
console, fixes them, re-runs until clean; only then do schema migrations run.

```
make upgrade   (detects 1.x → 2.0)
 │
 ├─ 1. BACKUP  (mandatory, automatic, BEFORE any DB change)
 │      • pg_dump        → backups/pg-<ts>.sql.gz       (rollback safety net)
 │      • influxd backup → backups/influx-<ts>/         (handed to user; NOT converted)
 │
 ├─ 2. PREFLIGHT (read-only)   migration_doctor scan
 │      detects rows violating 2.0 invariants:
 │        • email blank / NULL
 │        • username != email
 │        • duplicate email (case-insensitive)
 │      prints: "Conflicts: N (blank X, mismatch Y, dup-groups Z)" + per-row table
 │
 ├─ 3. RESOLVE
 │      • AUTO (safe): lowercase email; email = username where only case/whitespace
 │                     differs; admin from ADMIN_EMAIL if provided
 │      • MANUAL (needs human):
 │          – interactive wizard: prompts per conflict, validates (valid email,
 │            no new collision), writes the fix
 │          – file fallback (headless): dump conflicts.yaml, operator edits emails,
 │            `apply` reads it back
 │        Same detector + same validation back both modes. Idempotent / resumable.
 │
 ├─ 4. GATE: conflicts remain → STOP, exit != 0, print the fix command. NO migrate.
 │
 ├─ 5. migrate   (now users/0013 applies cleanly)
 │
 └─ 6. bring up the 2.0 stack
```

### `migration_doctor` spec

- **On-premise only.** No change to `cloud-backend`; no upstream PR.
- **Runs against the still-running 1.2 backend image** (boots without the new
  TimescaleDB env vars), via Django ORM on `users_user`
  (`docker compose run`/`exec` with the script mounted). This sidesteps the
  new-image `ImproperlyConfigured` bootstrap problem.
- Touches only `username` / `email`. Two operator-facing UX modes (wizard + file),
  one shared detector/validator. Idempotent: safe to re-run until 0 conflicts.
- Realistic scale: admin + <10 emailless users, rare dups — small enough for a
  console wizard; blank emails genuinely require a human, so full-auto is impossible
  by design (and that's fine — the gate enforces it).

## Infrastructure / compose changes (from the 4-repo analysis)

Baseline for all repos: branch `onprem-release/1.2.0`.

| Component | Change required in on-premise compose / deploy |
|---|---|
| **backend** | New **required** TimescaleDB env vars (no defaults: `TIMESCALE_PRIMARY_DB_URL`, `TIMESCALE_MQTT_METRICS_*`, `TIMESCALE_VIEWS_READER_*`). New services: TimescaleDB, `license_service` (`LICENSE_SERVICE_BASE_URL`, `INTERNAL_LICENSE_SERVICE_TOKEN`). Grafana app wiring (`GRAFANA_URL`, `GRAFANA_UPSTREAM_URL`, `GRAFANA_ADMIN_MANAGEMENT_URL`). New Celery queues: `metrics_queue`, `grafana_queue`, `email_queue` (+ `default_queue`) — workers/beat must consume them. InfluxDB removed. |
| **frontend** | Lockstep with backend (login `username`→`email`, new registration/verify/sessions/transfer endpoints). Env optional (`VITE_API_URL`, `SERVICE_NAME` for correctness). Stateless — no migration. |
| **tunnel** | JWT public key now a **mounted keyfile** + `BACKEND_APP_PUBLIC_KEY_PATH` (no default → authorizer won't start otherwise). `BACKEND_APP_PUBLIC_KEY` (PEM-content env) removed. `CLOUD_ABSOLUTE_SERVER_NAME_REGEX` now auto-derived (backward compatible). No state/migration; frp tokens unchanged → controllers not forced to reconnect. |
| **webssh** | Needs `redis_url` for SFTP download tokens (Redis already in on-premise compose — just wire it). No DB/auth/JWT changes. |

Much of this (TimescaleDB, Grafana, extra workers, pgcat) the `sync/upstream-parity`
branch already introduced — reconcile it with the real `main` requirements above.

## Grafana → built-in SQLite

Switch **Grafana's internal config DB** (dashboards/users/orgs) from the external
Postgres/pgcat pool to **`sqlite3`** under `/var/lib/grafana` (volume
`clientsGrafanaData` already persists it). Remove the internal-DB plumbing:
- `grafana/clients-grafana.ini` `[database]` → `type = sqlite3` (drop `host/name/user/password`).
- `postgres/init-grafana-db.sh` (grafana DB creation) — remove.
- pgcat grafana pool entries (`pgcat/pgcat.toml`) — remove.
- `GRAFANA_DB_*` env vars — remove.

**Keep** TimescaleDB as Grafana's **datasource** (`GRAFANA_TIMESCALE_*`) — that is the
metrics store, untouched. Backend talks to Grafana over HTTP (`GRAFANA_*_URL`), never
its internal DB, so the switch is isolated.

## Metrics history

InfluxDB → TimescaleDB conversion is **not** attempted (costly/fragile). On the 1→2
upgrade we **back up the InfluxDB database** and keep it alongside for the user.
New metrics accumulate in TimescaleDB. Documented in CHANGELOG and upgrade docs:
"metrics history is preserved in the backup; restore/use later if needed."

## Backup invariant

A backup (Postgres `pg_dump` + InfluxDB `influxd backup`) is **mandatory before the
1→2 transition and before any DB-mutating step** on the automatic path. Reuse the
existing `postgres-backup` service; add an InfluxDB backup step.

## Versioning & changelog

- `VERSION` → `2.0.0`.
- `CHANGELOG.md` / `CHANGELOG_EN.md`: breaking 2.0; mandatory backup; email-as-login;
  interactive `make upgrade` conflict resolution; InfluxDB backup + metrics reset note;
  Grafana internal DB now SQLite; new required services/env.

## Work breakdown

1. `migration_doctor` tool (detector + wizard + `conflicts.yaml` mode + validation) — on-premise.
2. `make upgrade` / `make fix-users` orchestration (backup → doctor → gate → migrate → up).
3. InfluxDB backup step; confirm `postgres-backup` covers the pg dump.
4. Compose: TimescaleDB env/services, `license_service`, Grafana wiring, Celery queues,
   webssh `redis_url`, tunnel keyfile mount + `BACKEND_APP_PUBLIC_KEY_PATH`, frontend env.
5. Grafana → SQLite (remove external-DB plumbing).
6. `VERSION` → 2.0.0, CHANGELOG, upgrade docs.
7. Reconcile with what `sync/upstream-parity` already added.
```
