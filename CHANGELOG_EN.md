# Changelog

All notable changes to this project are documented in this file.

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
