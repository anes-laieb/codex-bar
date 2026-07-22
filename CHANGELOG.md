# Changelog

Notable changes to Codex Bar are recorded here.

This project follows a release-oriented changelog. Dates use ISO 8601 and versions match
the application bundle version.

## Unreleased

- No user-facing changes recorded yet.

## 2.1.11 - 2026-07-22

### Added

- Added a direct in-app updater to the menu-bar **Update Available** action.
- Added a focused progress window with download progress and cancellable downloads.

### Security

- Require the architecture-specific GitHub release asset and its GitHub-provided SHA-256
  digest before an update can be installed.
- Validate the extracted app's bundle identifier, version, architecture, and code
  signature before replacing the installed copy.
- Keep the existing app as a rollback copy until the updated version launches, and leave
  the current installation untouched when its destination is not writable.

### Changed

- Relaunch Codex Bar automatically after a successful update instead of opening the
  release page in a browser.
- Documented updater network behavior, verification, permissions, and the one-time manual
  upgrade required from versions that predate the in-app installer.

### Packaging

- Added a compressed macOS DMG with the standard drag-to-Applications layout and a
  separately published SHA-256 checksum.
- Extended the release script to build and validate ZIP and DMG artifacts from the same
  signed application bundle.

## 2.1.10 - 2026-07-22

### Documentation

- Added a dedicated menu-bar walkthrough covering idle, working, attention, the open
  session menu, usage, and Quick Preferences with fictional demo data.
- Added icon-led links for issues, contribution policy, security, support, and conduct.
- Added icons to the major README sections and separated the menu-bar experience from
  the full sessions-window preview.
- Consolidated media provenance and capture guidance into `docs/CAPTURE.md`, removing
  the unnecessary nested `docs/assets/README.md`.
- Replaced the Apache appendix placeholder with the project's actual 2026 contributor
  copyright notice while retaining the complete license terms.

### Release

- Bumped the application and release package to 2.1.10 so the latest published archive
  matches the corrected documentation and bundled license notice.

## 2.1.9 - 2026-07-22

### Added

- Added separate Default, System, and Sky Blue menu-bar icon appearances.
- Added the Default appearance using the branded full-color idle artwork.

### Changed

- Kept System as the fresh-install default so the template SVG follows macOS light/dark
  menu-bar contrast automatically.
- Updated the README appearance comparison to show the correct System SVG instead of
  labeling the full-color Default artwork as the idle/system presentation.

### Compatibility

- Existing `system`, `skyBlue`, and legacy `colored` preferences continue to resolve to
  the same appearance after updating.

## 2.1.8 - 2026-07-21

### Added

- Multi-session discovery backed by Codex's local thread index and open rollout logs.
- Direct `codex://` links for opening an existing task or starting a new chat.
- Pin, mute, hide, and restore controls for individual sessions.
- Actionable completion and attention notifications.
- Separate completion/question sounds, previews, and scheduled quiet hours.
- Recent activity history, weekly usage display, and optional release checks.
- System and sky-blue status-icon appearances with animated working artwork.
- Optional timer, Dock visibility, and Launch at Login preferences.

### Changed

- Redesigned the menu-bar menu and sessions window around multiple concurrent tasks.
- Replaced the former sparkle status treatment with supplied Codex status artwork.
- Updated the app icon pipeline and bundled the new status assets.
- Updated installation output and user documentation for the new experience.
- Added a product-focused README with branded artwork and an application preview.
- Added a validated release-packaging workflow with architecture-specific archives and
  SHA-256 checksums.

### Privacy

- Session processing remains local.
- The GitHub releases API is contacted only for enabled or manually triggered update
  checks.
