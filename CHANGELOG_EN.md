# Changelog

All notable changes to this project are documented in this file.

## [1.3.0] - 2026-06-09

### Added

- Email sending can now be fully disabled via the `EMAIL_ENABLED=False` variable: the `EMAIL_*` variables are no longer required, invitations and password resets are handled through the admin panel.
- Admin panel action for generating a one-time password reset link (works without email).
- Documentation: external reverse proxy in front of the cloud (nginx and Traefik, L4 TCP passthrough); network diagram, ports and firewall rules (`doc/SECURITY_NETWORK.md`); admin panel section; deployment in a private LAN without public access (public certificate + internal DNS).

### Fixed

- Backend crash on startup when `EMAIL_URL` is empty.
- nginx configuration example (SNI-based routing): the regex did not match the cloud's root domain.

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
