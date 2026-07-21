# Changelog

Notable changes to Codex Bar are recorded here.

This project follows a release-oriented changelog. Dates use ISO 8601 and versions match
the application bundle version.

## Unreleased

- No user-facing changes recorded yet.

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

### Privacy

- Session processing remains local.
- The GitHub releases API is contacted only for enabled or manually triggered update
  checks.
