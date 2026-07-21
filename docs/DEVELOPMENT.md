# Development

This document describes the local maintainer workflow. The project currently accepts
issues but does not accept external pull requests; see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Prerequisites

- macOS 13 or newer;
- Xcode or the Xcode Command Line Tools;
- Codex Desktop or Codex CLI for live integration testing;
- the system `sqlite3`, `lsof`, `sips`, `iconutil`, `codesign`, and `qlmanage` tools.

No third-party package manager or Swift dependency is required.

## Build

From the repository root:

```sh
sh app/build.sh
```

The bundle is written to `app/build/Codex Bar.app`. To build into an isolated directory:

```sh
build_dir="$(mktemp -d)"
sh app/build.sh "$build_dir"
```

To install and launch a fresh local build:

```sh
./install-app.sh
```

The installer replaces any existing local Codex Bar application and stops the legacy
SwiftBar watcher, so save any local runtime state you need before using it.

## Verification

There is not yet an automated test suite. Before a release, perform at least these
checks:

```sh
sh -n app/build.sh
sh -n install-app.sh
sh -n install.sh
sh -n uninstall.sh
sh app/build.sh
plutil -lint app/Info.plist
codesign --verify --deep --strict "app/build/Codex Bar.app"
```

Then test the built application manually:

- idle, working, completed, question, approval, and aborted task states;
- multiple simultaneous sessions and exact-task deep links;
- pin, mute, hide, restore, and recent-activity behavior;
- notification actions and completion/question sound settings;
- quiet hours across midnight;
- timer, Dock, appearance, and Launch at Login preferences;
- empty state with no Codex task open;
- manual/automatic update checks and offline failure behavior;
- Light and Dark appearances at standard and Retina display scales.

## Release checklist

1. Update both version values in `app/Info.plist`.
2. Move the release notes from `Unreleased` into a dated section in `CHANGELOG.md`.
3. Run the verification commands and manual test matrix above.
4. Build the release archive and checksum with `scripts/package-release.sh`.
5. Confirm the archive architecture, minimum macOS version, signature type, bundled
   `LICENSE`/`NOTICE`, and checksum are described accurately in the release notes.
6. Confirm `git status` contains no build output or private session material.
7. Tag the reviewed commit with the same version prefixed by `v`.
8. Publish the ZIP and `.sha256` file together, then confirm the in-app update check sees
   the new release.

## Design constraints

- Never edit `~/.codex/config.toml` from the native app.
- Treat rollout events as version-dependent input: ignore unknown records and fail safely.
- Keep session contents local except for text explicitly shown in a local notification.
- Preserve support for a source-only, dependency-free build.
- Keep the legacy SwiftBar path isolated from native-app behavior.
