# Changelog

All notable changes to OnlineCopyPaste (`cp`) are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-28

First public release.

### Added

- Notes addressed by short codes: public (`/<code>`) and private (`/private/<code>`,
  behind HTTP basic auth); `priv/<code>` on the entry page opens a private note.
- Note creation and settings under `/new`, behind basic auth; editable notes open in
  the editor after creating or saving.
- Modes: editable by anyone with the link, read-only, and burn after reading (revealed
  only by POST, so link previews cannot burn it).
- Optional per-note password (argon2id), unlock cookie bound to the note and password.
- Expiry: 7 days after the last change (public default), 1 h, 1 day, 7 days or never.
- Autosave with conflict detection, and live updates by polling every 3 s while the tab
  is visible, keeping the caret next to its text.
- Share button that copies the note's canonical URL; copy, raw text and delete actions.
- Command-line access with curl (`?raw`, `?a=save`, `?a=poll`, `?a=reveal&raw`).
- 14 themes chosen per instance in `etc/theme`, including light/dark pairs; animated
  octopus logo that honours `prefers-reduced-motion`.
- Neutral entry and "Nothing here" pages that do not reveal what the site is.
- Several instances per server (`CP_NAME`, `CP_USER`, `CP_GROUP`).
- Hardened deployment: one fixed PHP entry point, dedicated php-fpm pool with
  `open_basedir` and disabled functions, size-capped `noexec` data image, strict CSP,
  CSRF checks, rate limits (IPv6 per /64), purge timer.
- Manual install guide, optional `install.sh`, `tools/audit.sh` security audit,
  `SECURITY.md`, and app, nginx and browser test suites run in CI.

[Unreleased]: https://github.com/juanmitaboada/copypaste/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/juanmitaboada/copypaste/releases/tag/v1.0.0
