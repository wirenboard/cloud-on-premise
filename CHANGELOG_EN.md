# Changelog

All notable changes to this project are documented in this file.

## [2.0.0] - 2026-08-11

> Breaking release. See [`RELEASE_NOTES_2.0.md`](RELEASE_NOTES_2.0.md) for the
> upgrade procedure.

### Added

- Controller web services open straight from the cloud: Node-RED, Home Assistant, Zigbee2MQTT, ESPHome and others are reachable by link through a secure tunnel, with no VPN and no port forwarding. Custom services on any port can be added too (up to 20 per controller).
- Two-factor authentication: recovery codes, an organization-wide 2FA requirement, and code confirmation for dangerous actions.
- Session management: active devices with browser, IP, country and city; terminate a single session or every session on other devices.
- Controller transfer between organizations — confirmed by the receiving side, with the option to cancel the request.
- Controller metrics and per-organization Grafana dashboards: dashboards are created automatically with the first controller, opened from the cloud without a separate password, and metric reporting can be turned off per controller.
- Metric alerts: an organization configures its own rules in Grafana, and the emails go through the SMTP server from `.env`.
- Deleting an entire organization, confirmed with a two-factor code.
- Email confirmation on sign-up and changing your email in the account settings.
- Organization invitations are now accepted by already registered users as well.
- Web console on a phone: a special-key panel, sticky Ctrl and Alt, full-screen mode, and a terminal that adapts to the on-screen keyboard.
- Web console file manager: file sizes and types, deletion, uploads up to 350 MB, and reliable downloads of large files.
- Password reset links are generated from the admin panel — for installations with no email configured.
- Nightly database backups and a guided one-command update, `make upgrade`.
- Configurable metrics retention (`METRICS_RETENTION_DAYS`, 30 days by default).

### Changed

- Signing in now uses the email address: it is mandatory, unique, and replaces the login.
- Sign-up became a two-step flow — a request, then a link from the email; the sign-up page addresses changed.
- After signing in, the user returns to the page they were asked to authenticate from.
- Opening a tunnel to a controller is noticeably faster.
- Firmware versions are sorted sensibly: stable releases first, test builds after.
- The default Node-RED port is now 21880.
- Changing the password or signing out also ends the sessions in the metrics dashboards.
- The metrics store moved from InfluxDB to TimescaleDB; previously collected history does not carry over into the new charts.
- SMTP settings are configured with separate variables (`EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`) instead of a combined URL, and `EMAIL_ENABLED` must be set explicitly.

### Removed

- Signing in with a login, and the "username" field on sign-up.
- The InfluxDB service — replaced by TimescaleDB and Grafana.

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
