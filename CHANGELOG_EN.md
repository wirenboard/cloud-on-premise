# Changelog

All notable changes to this project are documented in this file.

## [1.2.0] - 2026-05-29

### Added

- The organization invitation email subject and body can now be overridden via the `INVITE_EMAIL_SUBJECT` and `INVITE_EMAIL_BODY` environment variables. When unset (or empty) the built-in RU/EN translation is used, selected by the inviter's language. The body supports `\n` line breaks; the invitation link is always appended at the end.

### Changed

- Automated the release pipeline: a new “Start Release” workflow creates `onprem-release/X.Y.Z` branches across all five stack repositories in one click, bumps `VERSION`, and appends a `CHANGELOG` entry.
- Added a “Deploy to test server” workflow that rolls out testing images to the dev server over SSH from GitHub Actions with a single click.
- Switched the `make_release.yml` release workflow from a manually-issued PAT to the built-in `GITHUB_TOKEN` with explicit `packages: write` permissions, fixing GHCR authorization failures. Removed the empty `tls/.gitkeep` and the `jwt/` directory from the GitHub Release asset set — they were breaking publication.

### Fixed

- Frontend: correct browser-locale detection (non-standard values now fall back to the nearest supported one) and reliable propagation of the `Accept-Language` header on backend requests — fixes cases where invitation emails arrived in an unexpected language.

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
