# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Before the update

- The update goes through the `wb-onprem` utility: it checks the installation, backs up the volumes, switches the version and rolls it back on failure. `make update` calls the utility and without it refuses with a link to its releases. `make run` and `make restart` refuse while the server has containers of another version of the cloud, stopped ones included: `make stop` no longer removes them. When the containers are removed but the database is still there, `make run` and `make restart` compare the version of the files with the version of the last start; on an installation that has no such record yet (2.0.1 and earlier) they refuse and suggest starting the previous version with its own files and running `make update`.
- User logins become unique regardless of letter case. If the installation has logins that differ only by case, the update stops before changing anything: rename or delete one login of each pair in the admin panel and run the update again.
- In the free (FREE) edition, the only one so far, a controller can be added only if the cloud server sends metrics to `on-premise-metrics.wirenboard.cloud`: with outbound access there closed, the cloud refuses to add it. An error response from the metrics server does not block adding, and controllers already added keep working as before. If the server reaches the internet through a proxy, set it with `HTTPS_PROXY` in `.env`.
- Backend images are built on Debian 13 and Python 3.11 with current security fixes and are half the size. If emails stop going out with an SSL error after the update, the mail server uses outdated encryption (a SHA-1 signed certificate or legacy TLS renegotiation): update it or set another server in `EMAIL_HOST` in `.env`.

### After the update

- Every user signs in once more: the sign-in cookies are renamed.
- The web interface works only at `https://${ABSOLUTE_SERVER}`. Opened by IP address or another name, sign-in and any change get a 403 refusal.
- Controller web interface and SSH tabs opened through a tunnel reload once: the tunnel access key is bound to the cloud session, and old keys are no longer valid.
- The cloud does not open in a frame (iframe) on other sites.
- Pending email change requests are deleted: the change has to be requested again.
- If several users were linked to one Grafana account, the link is removed and the cloud connects them to the organisation metrics again.
- The CARTO map key `CARTO_API_KEY` and the invitation email texts (`INVITE_EMAIL_SUBJECT`, `INVITE_EMAIL_BODY`) move from `.env` to the admin panel once, on the first start of 2.1.0, and are changed there afterwards. The branding variables from `.env` are copied to the admin panel too (Settings → Branding); the web interface takes the footer link, the documentation links and the status page from `.env`, as in 2.0.1.
- The map key moves only from `CARTO_API_KEY` in `.env`. If in 2.0.1 only the frontend got the key, for example through `docker-compose.override.yml`, the maps and the address search stay hidden after the update until the key is set in the admin panel (Settings → Maps).
- The MinIO file storage is replaced with SeaweedFS, and its data is not carried over. A controller diagnostic archive requested before the update has to be requested again.
- The `minio` and `minio-client` containers are removed on the update, their volume stays. If the diagnostic archives in it are not needed, remove it: `docker volume ls -q --filter name=minioData` shows its name, `docker volume rm <name>` removes it.
- If `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` are not set in `.env`, `make generate-env` writes random ones there (target `make generate-s3-keys`). On an installation that ran with the default keys they change on the update; keys already set stay.
- After changing their email, a user could not open metrics: the Grafana login stayed the old one. The login changes together with the email, and accounts affected earlier are fixed with `docker compose exec -w /src backend uv run --no-dev ./manage.py fix_grafana_logins --apply`; without `--apply` it only shows what it would fix.

### Security

- Traefik is updated to 3.7.16 (CVE-2026-32305, CVE-2026-71324). Headers with anything but letters, digits and hyphens in the name are dropped, so an agent cannot pose as another controller by forging the client certificate header. Such headers do not pass through HTTP tunnels either.
- The clients Grafana password reset could be reached past the block through `%2F`, repeated slashes or another letter case, and Grafana's own metrics (`/metrics`) were open to everyone. Both paths are closed.
- Grafana is updated to 12.4.14, Redis to 7.4.12. Grafana requests with a body are limited: up to 4 MB in, up to 30 at a time from one IP address.
- The metrics database is updated to PostgreSQL 17.11 and TimescaleDB 2.30.2, closing PostgreSQL vulnerabilities that let a user with Grafana access run code on the database server. The TimescaleDB extension is updated automatically on start; going back to 2.0.1 after that is possible only from a backup of the metrics volume together with the old image.
- A Grafana user with access to their organisation's metrics saw other organisations' rows in a query error message and could read the metrics database statistics (per-table counters of rows read). Closed.
- A Grafana user can no longer run EXPLAIN, get query plans through `debug_print_*`, create temporary objects in the metrics database or connect to `template1`.
- A controller page opened through a tunnel could send requests to the cloud API as the visitor. Changing requests with a foreign `Origin` are refused, and the sign-in cookies are not sent to subdomains.
- Changing the email requires the current password, and the old address gets emails about the request and the change. A password reset, any password change (from the admin panel and with `changepassword` included) and an email change end all sessions of the user.
- A password could be guessed from different addresses. After 50 wrong passwords within an hour, signing in to the account is locked for an hour and the owner gets an email; a password reset lifts the lock at once.
- A 2FA code could be guessed. Wrong codes are counted per user: after 5 failures code entry is closed for 15 minutes, each next lock is twice as long (up to 4 hours), and the owner gets an email. The limits are set by `TOTP_FAILURE_LIMIT`, `TOTP_LOCKOUT_TIME` and `TOTP_MAX_LOCKOUT_TIME`.
- A staff member with 2FA could enter the admin panel without the code by adding a space to the login. Signing in to the admin panel with 2FA asks for the code every time.
- Password changes are limited to 5 attempts a minute and 20 a day.
- Accepting an organisation invitation signed in to an existing account without the password and 2FA, and a request without the invitation token got a 500 error. Closed; the password on accepting an invitation is checked by the same rules as on registration.
- Attaching controllers to a group or detaching them revealed whether a controller with someone else's serial number existed in the cloud. A foreign serial gets the same answer as a nonexistent one: "Controllers not found". A demo user cannot detach controllers from groups.
- A user removed from an organisation, deactivated or deleted, as well as a member of an organisation a controller was transferred from, kept the controller web interface and SSH opened through a tunnel. Access is lost at once, and the connection of the controller's other users reconnects.
- The file storage served diagnostic archives from a public bucket. The SeaweedFS bucket is closed by keys, and an archive is downloaded only through a signed link.
- Images are rebuilt without the vulnerable brotli library (CVE-2026-111497): the tunnel authorizer on nginx 1.30.6, the frontend and the web console on Node 24.22.3. In the backend image brotli 1.2.0 stays inside Pillow: the backend opens only branding PNG and ICO files with Pillow, and the vulnerable font decoder is never called.
- Django is updated to 5.2 LTS, and vulnerable dependencies of the backend and the web console are updated.
- In a CSV export of controllers, values starting with `=`, `+`, `-` or `@` are escaped with an apostrophe so that a spreadsheet does not run them as a formula.

### Fixed

- The controller web interface through a tunnel threw the user back to the sign-in form after a correct password when the cloud domain had a foreign cookie whose name ends in `id` (for example, Yandex Metrica's `_ym_uid` on the parent domain).
- A controller tunnel did not come back after the cloud dropped its connection (sign-out, hang, admin panel): no new connection was issued.
- The "500 Server error" screen during a backend restart stayed until the page was reloaded. The service retries the request itself and opens the page.
- A member of an organisation with mandatory 2FA who had no 2FA could neither open the organisation list nor leave the organisation.
- A double click in the invitation window sent several invitations with different links.
- Malformed API requests got a 500 error, and the "Download diagnostics" button silently did nothing after the session ended.
- Telegraf dropped the whole batch of metrics when a controller sent an extra tag, a numeric value or a NUL character, and changed the structure of the metrics table. Only host, topic and value are written, and NUL is stripped. When the metrics database is down at start, Telegraf retries the connection.
- Searching the controller list broke the table on special characters, and a link with a search opened with the wrong "search in" checkboxes.
- In the web console, files with Cyrillic names could not be downloaded or uploaded. The terminal reconnects to the same session after the browser is minimised or the network drops, and folders with many symlinks open faster.
- The backend log got a traceback about the unreachable license service on every request, and the warning about a missing GeoIP database repeated on every sign-in.
- Invitation, controller transfer and registration confirmation emails named the product Wiren Board Cloud even when the admin panel set another name.

### Changed

- The logo and icons can be uploaded from the admin panel (Settings → Branding): the files are saved to the `branding/` directory.
- The product name and primary color from the admin panel apply to the SSH and file manager pages too. `SERVICE_NAME` and `PRIMARY_COLOR` from `.env` stay as the fallback: they apply while the admin field is empty or the backend has been unreachable since the web console started.
- The CARTO map key is set in the admin panel (Settings → Maps). Without a key the maps and the address search are hidden.
- The address search does not send the Wiren Board email to the OpenStreetMap geocoding service.
- The interface fonts are part of the frontend build and are not loaded from Google Fonts.
- The MinIO file storage is replaced with SeaweedFS: MinIO images were removed from Docker Hub and get no security fixes. The image comes from the `ghcr.io/wirenboard/on-premise` mirror.
- The controller list is exported to a file in full, up to 5000 controllers; with more, the file comes with a warning.
- A tunnel opening error names the cause: the tunnel is not connected, the controller did not answer, or the service on the controller returned an error.
- Password reset and 2FA emails come in the language of whoever requested them.

### Added

- The metrics send interval is set per controller: from 60 to 240 seconds, 120 by default.
- The interface languages and the default language are chosen in the admin panel (Settings → Interface languages).
- An email to the account owner on a sign-in from a new device.
- The last column of the controller export is the time of the agent's last contact.
- Backup mail servers: if the main one does not accept an email, it goes through the next one from `EMAIL_FALLBACK_URLS`.
- A proxy for internet access: `HTTPS_PROXY` and `NO_PROXY` in `.env`; the cloud services reach each other past the proxy.
- Web console settings in `.env`: terminal resume after a dropped connection (`WS_RESUME_*`) and the SSH, SFTP and file deletion timeouts (`SSH_CHANNEL_TIMEOUT`, `SFTP_TIMEOUT`, `DELETE_TIMEOUT`).

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
