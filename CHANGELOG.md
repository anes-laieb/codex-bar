# Changelog

Notable changes to Codex Bar are recorded here. Dates use ISO 8601 and versions match
the application bundle version.

## Unreleased

- No user-facing changes recorded yet.

## 1.0.0 - 2026-07-22

The first stable public release of Codex Bar.

### Application

- Added native macOS menu-bar and sessions-window experiences for monitoring concurrent
  Codex tasks.
- Added idle, working, and needs-attention states with authored icon artwork, animation,
  optional timers, and live activity text.
- Added exact-task Codex links, New Chat, pin, mute, hide, restore, recent activity, and
  weekly usage controls.
- Added actionable completion and question notifications, independent sounds, previews,
  scheduled quiet hours, Dock visibility, and Launch at Login.
- Added Default, System, and Sky Blue menu-bar icon appearances.
- Fixed session titles and metadata so narrow windows truncate to one line instead of
  wrapping and overlapping adjacent rows.

### Updates and security

- Added verified one-click updates with visible progress, cancellable downloads, and an
  automatic relaunch.
- Require the matching architecture-specific GitHub release asset and its GitHub-provided
  SHA-256 digest before installation.
- Validate the extracted app's bundle identifier, version, architecture, and code
  signature, while retaining the installed bundle for rollback until relaunch succeeds.

### Packaging and documentation

- Added validated ZIP and branded drag-to-Applications DMG packages with separate
  SHA-256 checksums.
- Added complete project documentation for installation, architecture, development,
  capture provenance, privacy, security, support, contribution policy, and conduct.
- Added an icon-led product README with real application and menu-bar walkthroughs.

### Privacy

- Session processing remains local and Codex configuration is never modified.
- Network access is limited to optional release metadata checks and user-started update
  downloads from GitHub Releases.
