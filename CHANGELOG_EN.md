# Changelog

All notable changes to this project are documented in this file.

## [2.0.0] - 2026-08-12

> Breaking release. See [`RELEASE_NOTES_2.0.md`](RELEASE_NOTES_2.0.md) for the
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
- **One-command installation on AWS:** the Terraform module in `terraform/aws` creates the server, the DNS records, the wildcard certificate and its renewal. Optionally sets up email through SES. Version upgrades still go through `make update` on the server, not through Terraform.
- **Unattended installation on any host:** `scripts/bootstrap.sh` installs Docker, fetches the release and starts the cloud on a clean Ubuntu; `make init-env` builds `.env` from environment variables instead of an editor.
- Passwords containing `$` are no longer truncated in `.env`: `make init-env` escapes it for docker compose. When editing `.env` by hand the character still has to be doubled (`$$`).
- GitHub Releases now carry `scripts/`, `doc/` and `terraform/` — without the first one, `make run` from a release archive did not work.

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
