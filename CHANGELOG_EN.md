# Changelog

All notable changes to this project are documented in this file.

## [2.1.0] - 2026-12-01

### Before the update

- From 2.0.1, update once with `git pull && make update`; after that `make update` is enough: it downloads the release files and images itself, dumps the main database (the last three dumps are kept) and only then switches the version.
- The dump does not cover the metrics database, and once TimescaleDB is upgraded 2.0.1 no longer starts on it. To be able to roll back, take a snapshot of the server or a copy of the volumes (README, "Updating").
- Logins that differ only by letter case stop the update before any change: rename or delete one login of each pair in the admin panel.
- A controller can be added only if the cloud server sends metrics to `on-premise-metrics.wirenboard.cloud`. A proxy to the internet is set with `HTTPS_PROXY` in `.env`.
- Backend images are built on Debian 13. If emails stop going out with an SSL error, the mail server uses outdated encryption: update it or change `EMAIL_HOST`.
- `make run` and `make restart` refuse while the server has containers of another version of the cloud; `make stop` no longer removes containers.

### After the update

- Every user signs in once more; controller web interface and SSH tabs opened through a tunnel need a reload.
- The web interface works only at `https://${ABSOLUTE_SERVER}` and does not open in a frame on other sites.
- Pending email change requests are deleted.
- The map key `CARTO_API_KEY`, the invitation email texts and the branding move from `.env` to the admin panel once and are changed there afterwards. A key given only to the frontend through `docker-compose.override.yml` is not moved: set it in the admin panel (Settings → Maps).
- The MinIO file storage is replaced with SeaweedFS, with no data carried over: request diagnostic archives again. Remove the old volume by hand: `docker volume rm <project>_minioData`.
- If `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` are not set in `.env`, the update writes random keys there.
- Excess Grafana organisations are removed during the update. Grafana accounts broken by an email change are fixed with `docker compose exec -w /src backend uv run --no-dev ./manage.py fix_grafana_logins --apply`.

### Security

- Updated Traefik 3.7.16, Grafana 12.4.14, Redis 7.4.12, PostgreSQL 17.11 and TimescaleDB 2.30.2 in the metrics database, Django 5.2 LTS and dependencies; images are rebuilt without the vulnerable brotli library.
- A Grafana user can no longer run code on the metrics database server or learn other organisations' data through query errors, database statistics and EXPLAIN.
- An agent can no longer pose as another controller by forging a header. The Grafana password reset and its `/metrics` are closed from outside.
- A controller page opened through a tunnel can no longer send requests to the cloud API as the visitor.
- Guessing a password or a 2FA code locks the sign-in and emails the owner (2FA limits — `TOTP_*`). Admin sign-in with 2FA always asks for the code, password changes are rate-limited.
- Changing the email requires the password and notifies the old address; a password or email change ends all sessions.
- Accepting an invitation no longer signs in to an existing account without the password and 2FA.
- A user removed from an organisation or deactivated loses the controller web interface and SSH opened through a tunnel at once.
- A serial number no longer tells whether someone else's controller exists in the cloud. Diagnostic archives are no longer in a public bucket. CSV export escapes formulas.

### Fixed

- The controller web interface through a tunnel threw the user back to sign-in because of a foreign cookie on the parent domain (for example, Yandex Metrica).
- A tunnel did not recover after the cloud dropped its connection.
- The "500 Server error" screen during a backend restart stayed until the page was reloaded.
- A member of an organisation with required 2FA and no 2FA enabled could not leave the organisation.
- A double click sent several invitations.
- Telegraf lost a batch of metrics because of an extra tag or a NUL character.
- Search in the controller list broke on special characters.
- The web console did not download or upload files with Cyrillic names.
- The backend log was flooded with tracebacks about the license service and GeoIP warnings.
- Emails called the product Wiren Board Cloud instead of the name set in the admin panel.

### Changed

- Logo, icons, the CARTO map key and interface languages are set in the admin panel. The name and colour from the admin panel apply to the web console too.
- Interface fonts are bundled, Google Fonts is not needed. Address search does not send the Wiren Board email to the OpenStreetMap service.
- The controller export holds up to 5000 rows and the agent's last contact time.
- A tunnel opening error names the cause.
- Password reset and 2FA emails come in the user's language.
- The web console terminal returns to the same session after a connection drop.

### Added

- Metrics sending interval per controller: from 60 to 240 seconds.
- An email to the owner on sign-in from a new device.
- Fallback mail servers `EMAIL_FALLBACK_URLS`, proxy `HTTPS_PROXY` and `NO_PROXY`, web console timeouts (`WS_RESUME_*`, `SSH_CHANNEL_TIMEOUT`, `SFTP_TIMEOUT`, `DELETE_TIMEOUT`) in `.env`.

## [2.0.1] - 2026-09-30

### Fixed

- `make update` no longer stops the cloud when the images fail to download.
- The cloud version in the web UI and the admin could be shown with a `-testing` suffix.
- Connecting to a controller through the tunnel broke off when the tunnel temporarily throttled requests.

### Changed

- MinIO and mc images were removed from Docker Hub, so they now come from the `ghcr.io/wirenboard/on-premise` mirror.
- Maps from the CARTO service now require an API key. It can be set with the `CARTO_API_KEY` variable in `.env`; see "Controller map" in the README for how to get one.

### Added

- The "Documentation" link in the footer opens the page in the interface language. The English link is set with the `SERVICE_DOCS_URL_EN` variable.

## [2.0.0] - 2026-08-20

> Breaking release. See [`RELEASE_NOTES_2.0_EN.md`](migration/RELEASE_NOTES_2.0_EN.md) for the
> upgrade procedure.

### Added

- Controller web services open straight from the cloud: Node-RED, Home Assistant, Zigbee2MQTT and any service of your own on any port are reachable by link through a secure tunnel — no VPN, no port forwarding, no public IP.
- Controller metrics: per-organization Grafana dashboards and alerts on your own rules (free space, temperature, load) delivered by email.
- Two-factor authentication with recovery codes and an organization-wide requirement; dangerous actions ask for a code.
- Session management: devices with browser, address, country and city; end someone else's session with one click.
- Controller transfer between organizations — confirmed by the receiving side, cancellable while pending.
- Web console on a phone: a special-key panel, sticky Ctrl and Alt, full-screen mode. The file manager gained deletion and uploads up to 350 MB.

### Changed

- **Signing in uses the email instead of a login.** The email became mandatory and unique, and is confirmed by mail on sign-up. Accounts with no email, or whose login differs from it, are repaired during the upgrade — no data is lost.
- Opening a tunnel to a controller is noticeably faster.

### Infrastructure and deployment

- **The certificate must also cover `*.apps.<domain>`** — without it the cloud will not start. A DNS record is needed too: controller web services live on that subdomain.
- **A one-command update, `make upgrade`:** a mandatory backup, a check that the accounts fit the new schema, and only then the migration. While the data is not in order, the migration does not run.
- **The metrics store moved from InfluxDB to TimescaleDB.** Previously collected history does not carry over into the new charts: the upgrade keeps it in a backup alongside.
- **The database now runs with its safety guarantees on.** It used to write with durability and autovacuum disabled — a power cut could cost the database, and tables bloated over time.
- **SMTP settings are configured with separate variables** (`EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`), and `EMAIL_ENABLED` must be set explicitly. `make upgrade` converts the old ones for you.
- **The stack grew** — TimescaleDB, Grafana, Telegraf and two more background workers. The server requirements stay the same: background parallelism is sized for a hundred controllers by default and is tunable in both directions.
- Settings for your hardware and retention policy appeared: metrics retention, background task parallelism, session geolocation (see `.env.example`).

## [1.5.0] - 2026-07-28

### Added

- The company site footer link can now be overridden via the `FOOTER_SITE_URL`, `FOOTER_SITE_LABEL_RU`, `FOOTER_SITE_LABEL_EN` environment variables (see the Branding section in `.env.example`). When not set, the Wiren Board defaults are used.

### Changed

- The browser tab title now follows `SERVICE_NAME`: rebranding requires setting just one variable. The `HTML_TITLE` variable is retired — if still present in `.env`, it is simply ignored.

### Security

- Tunnel authorizer: closed two `tunnel_key` authorization bypasses. The nginx `auth_jwt` module is now built from the `wirenboard/ngx-http-auth-jwt-module` fork (2.0.2-wb3): the JWT signing algorithm is pinned and spoofed client claim headers are stripped.

## [1.4.0] - 2026-07-25

### Added

- Product name and web UI links can now be overridden via the `SERVICE_NAME`, `HTML_TITLE`, `SERVICE_STATUS_URL`, `SERVICE_DOCS_URL` environment variables (see the Branding section in `.env.example`). When not set, the Wiren Board defaults are used.
- The web console (webssh) now also uses branding assets from the `branding/` directory: the logo and icons are overridden the same way as in the main frontend.
- The web console (webssh) overrides the name in the tab title and login window via `SERVICE_NAME`, and points the logo link and the tunnel-error redirect to the installation domain (`ABSOLUTE_SERVER`) instead of `wirenboard.cloud`.
- Primary button color override via the `PRIMARY_COLOR` (hex) variable in the web UI and the web console. When not set, the default color is used.

## [1.3.0] - 2026-06-09

### Added

- Email sending can now be fully disabled via the `EMAIL_ENABLED=False` variable: the `EMAIL_*` variables are no longer required, invitations and password resets are handled through the admin panel.
- Admin panel action for generating a one-time password reset link (works without email).
- Documentation: external reverse proxy in front of the cloud (nginx and Traefik, L4 TCP passthrough); network diagram, ports and firewall rules (`doc/SECURITY_NETWORK.md`, RU/EN); admin panel section; deployment in a private LAN without public access (public certificate + internal DNS).

### Changed

- `EMAIL_ENABLED=True` is now explicitly present in `.env.example` (main section). Nothing changes for existing installations: when the variable is unset, email sending stays enabled as before.

### Fixed

- Backend crash on startup when `EMAIL_URL` is empty.
- nginx configuration example (SNI-based routing): the regex did not match the cloud's root domain.
- External reverse-proxy documentation: clarified that `your-domain.com` is the full cloud hostname including the subdomain (the `ABSOLUTE_SERVER` value); the Traefik example (case C) now warns about backslash escaping in YAML quotes (the `unknown escape character` error makes Traefik serve its default certificate instead of passing TLS through).

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

## [0.1.1] - 2025-08-14

### Changed

- Minor fixes and stability improvements.

## [0.1.0] - 2025-08-01

### Added

- First public release.

### Changed

- Updated the On-Premise section in the admin panel.
- Added a subsection with license and limit information.
- Improved the metrics subsection and its visual presentation.
- Fixed the `Invalid instance_uid` error.
- Applied other minor fixes.
