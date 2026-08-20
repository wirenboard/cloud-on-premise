# On-Premise 2.0 — what's new

A major release: a large sync with the current cloud plus incompatible changes to user
accounts. **No user data is deleted** — it is migrated in place.

A short list of changes is in [`CHANGELOG_EN.md`](../CHANGELOG_EN.md). This document has the
details and the upgrade procedure. The release includes everything from 1.3.0–1.5.0
(optional email, rebranding, the tunnel authorizer security fix).

---

## New features

### Grafana dashboards per organization
A new `clients-grafana` service (Grafana 12.2.2) — separate user dashboards broken down by
organization. Grafana keeps its own state (dashboards, users, organizations) in the built-in
SQLite (`/var/lib/grafana`, the `clientsGrafanaData` volume) and reads metrics from
TimescaleDB as a datasource.

### Metrics on TimescaleDB
The metrics store has moved from InfluxDB to **TimescaleDB**. Metrics from controllers are
now ingested by the **Telegraf** service (HTTPS + mTLS, rate limiting through Traefik). The
single-node deployment runs one TimescaleDB instance (without the upstream HA stack:
no Patroni/etcd/HAProxy).

> **Important:** the metrics history for the previous period is **not carried over** into the
> new charts. The existing InfluxDB database is saved into the backup during the upgrade, and
> new metrics accumulate in TimescaleDB from scratch. Charts covering the period before the
> upgrade will be empty; the historical data can be restored from the backup separately if
> needed.

### FRP tunnel webhooks
A separate backend instance, `tunnel-webhooks-backend`, handles FRP tunnel webhooks (isolated
from the main application traffic).

### A dedicated queue for email
A separate worker for email joins the existing background task queues — messages no longer
wait behind heavy metrics tasks.

### Controller web services through tunnels
Web interfaces of controller services (Node-RED, for example) are published on
`<serial>-<port>.apps.<domain>` subdomains — up to 20 services per controller, reachable only
through cloud authorization. This requires a wildcard DNS record `*.apps.<domain>` and a
certificate covering that domain: it is part of the mandatory set that `make check-certs`
verifies (see the README).

### Fast tunnels
A pool of pre-warmed channels to the controller — pages behind a tunnel open noticeably
faster.

### Session geolocation
Country and city in the list of active sessions. Enabled with `GEOIP_ENABLED=True` in `.env`:
the DB-IP City Lite database (~62 MB) is downloaded automatically on `make run`, after which
geolocation works without any outbound requests (see the GeoIP section of the README).

### Metrics retention period
A new variable, `METRICS_RETENTION_DAYS` (30 days by default) — how long the controller
metrics history is kept.

---

## Incompatible changes

### Login by email
The email has become the login: **mandatory and unique** (case-insensitively). Accounts
without an email, or with a login that does not match the email, are no longer allowed.
The new schema requires this at the database level but does not repair the accounts itself.
That is why a populated 1.x database has to be put in order **before** the migration — this is
what `make upgrade` does (see below), and **no data is lost** in the process.

### Registration endpoint
The old `/users-sign-up/` endpoint has been removed (upstream replaced it with
`/users/registrations/`). The bundled frontend is updated in step, so the registration page
keeps working for the user.

### `EMAIL_ENABLED` is now mandatory
The stack does not start without an explicit `EMAIL_ENABLED=True` or `EMAIL_ENABLED=False` in
`.env`. In 1.x an unset variable silently enabled email — now the choice has to be made
explicitly (otherwise mail could be quietly lost on a half-configured setup). `make upgrade`
carries the variable over from the old file as is. If it is not there (the `.env` predates
1.5.0, or the line was deleted), it stays empty and the upgrade stops until you choose `True`
or `False` explicitly.

### New names for the email variables
`EMAIL_URL` is no longer assembled: the SMTP settings are passed directly under Django's own
names — `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`,
`EMAIL_NOTIFICATIONS_FROM`, and `EMAIL_USE_TLS` (port 587) or `EMAIL_USE_SSL` (port 465). The
`make generate-email-url` target is gone. `make upgrade` converts the old variables
(`EMAIL_SERVER`, `EMAIL_LOGIN`, `EMAIL_PASSWORD`, `EMAIL_PROTOCOL`) to the new names
automatically.

### `ADMIN_USERNAME` is no longer set
The login is the email, so there is no separate user name: the administrator is created with,
and signs in by, `ADMIN_EMAIL`.

---

## Before the upgrade

You only need to upgrade **if** you are currently running version 1.x — the version is in the
`VERSION` file and in the footer of the web interface. Before `make upgrade`, make sure that:

- **The certificate has been reissued with `*.apps.<domain>`.** Controller web services are a
  standard feature of 2.0, so `*.apps.your-domain.com` belongs to the mandatory domain set. If
  your 1.x certificate does not cover it, `make upgrade` stops at the certificate check before
  the backup: reissue the certificate (see
  [TLS Certificates](../README_EN.md#4-tls-certificates)) and add the `*.apps` DNS record.
- **There is room for the backup.** The backup (`pg_dump` + `influx backup`) is written to
  `./backups` — make sure there is disk space for a copy of the database.
- **The 1.x stack is running.** Do not stop the containers before upgrading — `make upgrade`
  manages them for you. `migration_doctor` runs inside the live backend container, and on a
  stopped stack it runs as a one-off container instead — accounts can be repaired there too.
- **Every user must have a valid, unique email equal to the login.** That is the whole point of
  the migration. The conflicts you will have to resolve by hand:
  - **an admin without an email** (the typical 1.x case: `username="admin"`, `email=""`) —
    `MODE=auto` fills in `ADMIN_EMAIL` for them from the current `.env`, even when the backend
    container started without that variable. If the address has to be a different one, use
    `MODE=resolve`;
  - **users without an email** — a real email has to be provided for each of them;
  - **duplicate emails** (case-insensitively) — only one owner can keep the address, the rest
    have to be given a different one.
- **InfluxDB metrics are not converted.** The history is copied alongside where possible; new
  metrics accumulate in TimescaleDB from scratch. The copy is in `./backups/influx-<date>/`. If
  the upgrade printed a warning that the copy is empty, the history remains only in the
  `influxData` docker volume — do not delete it.
- **The server can carry 2.0.** Compared to 1.5.0 it adds TimescaleDB, Telegraf, Grafana,
  separate metrics and email workers, and a second backend for webhooks — it needs more memory.
  The pre-flight check only looks at disk, so check the
  [system requirements](../README_EN.md#minimum-system-requirements) and
  [background task performance](../README_EN.md#background-task-performance) in advance.
- **If there are no conflicts** (everyone already has a valid unique email = login), the
  migration goes through **without a single manual action**.

---

## How to upgrade (1.x → 2.0)

A single command does everything. The `upgrade` target only appeared in 2.0, so it does not
exist on a 1.x checkout:

```bash
git pull
make upgrade
```

There is no way around it: while the installation is still on 1.x, `make run`,
`make update` and `make restart` refuse to start and point here. Otherwise the 2.0
images would migrate the database on start — with no backup and no account repair.

It first runs six checks while the cloud keeps serving and **changes nothing** until all six
pass. You can run it as many times as you like — that is the upgrade rehearsal.

| Check | What it does |
|---|---|
| Configuration | Builds a new `.env` from `.env.example`, carrying over the values of the old one: same-named variables as they are, renamed ones under their new names, keys and tokens verbatim. The previous file is kept alongside as `.env.bak-<date>`. Required variables whose value cannot be derived are left **empty** — fill them in: the check treats an empty value of a required variable as unset. Optional ones get the example value. Across several runs there will be several `.env.bak-*` copies; the 1.x configuration is in the oldest one |
| Environment variables | All required ones are set, and `EMAIL_ENABLED` holds a recognized value |
| TLS certificate | Covers every domain, including the new `*.apps.<domain>` |
| Disk space | At least 6 GB on the partition holding the repository: the 2.0 images take about 5 GB. If Docker keeps images on a different partition (`docker info --format '{{.DockerRootDir}}'`), check the space there too |
| Images | Downloaded in advance — the downtime will not wait for the registry. The check does not show the reason for a failure, look it up by hand: `VERSION=$(cat VERSION) docker compose pull` |
| User accounts | Compatible with the 2.0 schema (the email becomes the login) |

**If the account check asked for repairs, take a dump first.** `make fix-users` in every mode
except `scan` rewrites the user table in the running 1.x database, and it does so before the
upgrade takes its own backup. The previous login/email pairs are not recorded anywhere, so the
order is: `make backup`, then the repair.

When everything is ready, the command shows what will happen next and **asks for confirmation**.
The default answer is "no", so the cloud cannot be taken down by accident. Without a terminal
(`ssh host 'make upgrade'`, for example) the confirmation cannot be given — run
`make upgrade CONFIRM=yes` instead.

After the confirmation the downtime begins:

1. **Backup** — `pg_dump` of the main database (and a copy of InfluxDB, if it is still
   running). The InfluxDB database is **not converted** into TimescaleDB — it is kept alongside
   so that the historical metrics can be consulted later if needed.
2. **Stopping the application.** The databases stay up — the migrations run inside them. The
   accounts are checked once more, with nothing writing to the database.
3. **Migrations** on the image of the new version.
4. **Start.** The cloud also pushes the metrics collection configuration to the controllers
   right away, instead of waiting for the half-hourly cycle.

**How long it takes.** Everything heavy has already been done before the downtime, so the window
is the time of the database dump plus the migrations: a few minutes on a typical installation.
Controllers reconnect on their own: the tunnel tokens do not change, nothing has to be
reconfigured on them.

**What to tell the users.** After the upgrade, signing in is by email rather than by login. For
those whose login did not match their email, it changes — warn them in advance.

**Decide before the upgrade.** The metrics retention period, `METRICS_RETENTION_DAYS`, is
written into the metrics store at the moment it is created, that is, during the upgrade. Later
it can only be lowered: raising it means recreating the store and losing the history. If the
default of 30 days does not suit you, uncomment and set the variable before `make upgrade`.

**The upgrade clears the 1.x leftovers itself.** The `influx` and `worker-influx` containers are
removed after the backup — their services do not exist in 2.0, and the worker on the old image
would otherwise keep writing against the new schema. The `influxData` docker volume stays where
it is: the historical metrics are not going anywhere.

If you enabled `GEOIP_ENABLED=True`, download the database: unlike `make run`, the upgrade does
not do it — `make update-geoip`.

### Resolving user conflicts

`migration_doctor` runs inside the still-running backend container (through the Django ORM,
touching only `username`/`email`) and is idempotent — run it until 0 conflicts remain.

Of the modes below only `scan` leaves the database untouched; `auto`, `resolve` and `dump` all
start with the same auto-fixes.

```bash
# Only report the conflicts — the one mode that changes nothing:
make fix-users MODE=scan

# Auto-fixes: an admin with an empty email gets ADMIN_EMAIL; an empty email whose login is
# itself an address adopts it; when login and email differ, the email wins — the user's login
# becomes the address. Empty addresses with nothing to derive from, and duplicates, are left
# to a human:
make fix-users MODE=auto

# Interactive wizard: the same auto-fixes first, then a prompt for an address per remaining
# conflict, validating the address and checking for collisions:
make fix-users MODE=resolve

# Headless mode (no TTY): dump the conflicts to a file, edit it, apply it. The dump is also
# preceded by the auto-fixes, so only what needs a decision ends up in the file:
make fix-users MODE=dump          # writes migration/conflicts.yaml
#   ...edit the new_email field in every row...
make fix-users MODE=apply         # reads the file back
```

When `make fix-users MODE=scan` reports `Conflicts: 0`, run `make upgrade` again — the
migration will go through and the 2.0 image will come up.

> ⚠️ Do not restart the 1.x stack between repairing the accounts and upgrading: on
> every start 1.x re-creates the `admin` user with the address from `ADMIN_EMAIL`,
> and the database gets a duplicate again. The upgrade will notice and stop — then
> re-run `make fix-users` and give the re-created `admin` any other address.

### If something goes wrong

Until the confirmation is given, the migration has not run and the cloud is working. But by
that point two changes may already have happened: `.env` has been rebuilt for 2.0 (the previous
one is kept alongside), and, if you ran `make fix-users` in any mode except `scan`, user logins
and addresses have been changed. Both are rolled back by hand only — the migration has nothing
to do with it.

If the migration failed, the failed migration is rolled back in full, but the ones applied
before it in the same run remain. That is why going back to the previous version has to happen
together with the database — and in exactly this order:

1. **Go back to the previous version of the code and shut the 2.x stack down.** This has to come
   first: while the 2.0 services are running, the database cannot be taken away from them.
   `--remove-orphans` also removes the containers of services that did not exist in 1.5.0:

   ```bash
   git checkout v1.5.0
   VERSION=$(cat VERSION) docker compose down --remove-orphans
   ```

2. **Restore the configuration.** You need the **oldest** of the `.env.bak-*` files: it was
   created by the first `make upgrade` run, and only it is still in the 1.x format. The newer
   copies no longer have the variables 1.5.0 needs to start:

   ```bash
   cp "$(ls -tr .env.bak-* | head -1)" .env
   rm -f backups/.upgrade-unfinished
   ```

   The second command clears the unfinished-upgrade marker: while it is there,
   `make run` and `make update` on a 2.0 checkout refuse to start.

   If the upgrade got far enough to create the 2.x metrics store, remove its volume:
   the passwords are baked into it on creation, and you have just restored a `.env`
   without them — the next `make upgrade` will generate new ones, and telegraf and
   Grafana would silently fail to connect. The volume only holds 2.x metrics, which
   you do not have yet; the InfluxDB history is not touched:

   ```bash
   docker compose rm -sf timescale 2>/dev/null || true
   docker volume rm "$(basename "$PWD")_timescaleData" 2>/dev/null || true
   ```

3. **Restore the database** from the dump taken before the migration. The existing database has
   to be recreated, or the restore trips over the tables that are already there:

   ```bash
   export VERSION=$(cat VERSION)
   docker compose up -d postgres
   docker compose exec -T postgres dropdb -U <POSTGRES_USER> <POSTGRES_DB>
   docker compose exec -T postgres createdb -U <POSTGRES_USER> -O <POSTGRES_USER> <POSTGRES_DB>
   gunzip -c backups/pg-<date>.sql.gz | docker compose exec -T postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB>
   ```

   `export VERSION` is needed by every `docker compose` command — without it compose
   prints a "VERSION variable is not set" warning on each call.

4. **Start the previous version:** `make run`.

The InfluxDB metrics history is copied into `backups/influx-<date>/` where possible. If the
upgrade printed the warning "the InfluxDB backup is EMPTY", there is no copy — the history
remains only in the `influxData` docker volume, do not delete it.

---

## Infrastructure changes

- **Grafana keeps its own state** (dashboards, users, organizations) in the built-in SQLite and
  reads metrics from TimescaleDB with a separate read-only role — no separate database for
  Grafana is needed.
- **The tunnel authorizer** reads the backend's public JWT key from a mounted file
  (`BACKEND_APP_PUBLIC_KEY_PATH`) rather than from a PEM-in-an-environment-variable.
- Redis `6-alpine` → `7.4.8-alpine`.

### Removed
- The `BACKEND_APP_PUBLIC_KEY` variable (PEM-in-env) of the tunnel authorizer.
- The InfluxDB service and the `INFLUXDB_USERNAME` / `INFLUXDB_PASSWORD` / `INFLUXDB_TOKEN`
  variables.
- The `ADMIN_USERNAME` variable and the generated `EMAIL_URL`, together with the
  `make generate-email-url` and `make generate-influx-token` targets.
