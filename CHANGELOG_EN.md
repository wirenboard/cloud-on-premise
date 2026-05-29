# Changelog

All notable changes to this project are documented in this file.

## [1.2.0] - 2026-05-29

### Added

- Customizable organization invitation email via the `INVITE_EMAIL_SUBJECT` and `INVITE_EMAIL_BODY` environment variables (empty values fall back to the built-in localization).

### Fixed

- Browser locale detection and `Accept-Language` header propagation — invitation emails no longer arrive in an unexpected language.

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
