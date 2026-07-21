# Codex Bar

A native macOS **menu-bar companion for [Codex](https://github.com/openai/codex)**.
Know at a glance whether Codex is **working** or **waiting for you**, then jump directly
to any open task.

![Codex Bar menu-bar states, window, and a turn-complete notification](docs/demo.svg)

> The image is a mockup. To add a real screen recording, see [docs/CAPTURE.md](docs/CAPTURE.md).

---

## What it does

- **All currently open sessions** in one window, named as `project / session` from their working-directory path.
- **Click any session** to open that exact task in the Codex app through its native `codex://threads/{id}` route.
- **Pin, mute, or hide sessions** from the window's context menu. Hidden sessions can be restored from the menu bar.
- **A polished icon-led menu** with live state, session switching, recent activity, preferences, updates, and no UI shadows.
- **Animated live activity text** (`Thinking.`, `Thinking..`, `Thinking...`) beside the menu-bar icon, with an optional elapsed timer and pixel-stable icon/timer/word positions.
- **Codex status artwork** with the Codex logo while idle and the supplied 121-frame GIF animation at its native 0.03-second frame cadence while working.
- **Transparent application artwork** that naturally follows the Light or Dark system/Dock background, plus an icon-only “Sky blue” appearance: supplied full-color artwork while idle and a sky-blue GIF while working.
- **Live menu tracking** keeps the icon, activity dots, and session timers moving while the menu is open.
- **Native actionable notifications** with “Open Task” and “Mute Session” actions.
- **Distinct configurable sounds** for completion and questions, including preview controls and scheduled quiet hours.
- **A sky-blue question indicator** with a pending-question count when multiple tasks need attention.
- **Recent activity history** for completed turns and questions.
- **Automatic release checks** with a manual check available from the menu.
- **A redesigned window and optional Dock icon** showing state, elapsed time, project/session, model, effort, and all preferences.
- **Launch at Login** support.
- **No config, no daemon, no `notify` hook.** It just reads Codex's own session logs, so it can't break your Codex setup and never edits `~/.codex/config.toml`.

---

## Install (one command)

```sh
git clone https://github.com/anes-laieb/codex-bar.git && cd codex-bar && ./install-app.sh
```

That builds **Codex Bar.app**, puts it in `/Applications`, and launches it. The Codex
status icon appears in your menu bar and a window opens. Tick **Launch at Login** so it's
always there.

**Requirement:** Apple's Swift toolchain (already present if you have Xcode; otherwise
run `xcode-select --install` once). macOS 13+.

That's it. No Homebrew or extra apps are required.

---

## Using it

| Menu-bar state | Meaning |
| --- | --- |
| Codex idle icon | **idle**: every task is caught up |
| Animated Codex icon + timer | **working**: at least one turn is in progress |
| Sky-blue dot + `Check Codex` | **needs attention**: Codex is waiting for an answer or approval |

- **Click the menu-bar icon** for live sessions, recent activity, quick preferences, updates, and app controls.
- **Click a session** to open its exact Codex task.
- **Right-click a window session** to pin it, mute its alerts, or hide it.
- **Click the Dock icon** (or "Open Sessions Window") for the full window.
- When a turn ends or needs your answer, you get a notification and its configured sound unless alerts are muted or quiet hours are active.

### Uninstall

Quit it from its menu (or the window), then drag **`/Applications/Codex Bar.app`** to the Trash. Nothing else is left behind.

---

## How it works

Codex writes a JSON log for every session under `~/.codex/sessions/**/rollout-*.jsonl`.
Codex Bar finds the rollout files currently held open by Codex, matches them to Codex's
local thread index, tails each one, and updates the session list, icon, and notifications:

| Codex log event | State | Notification |
| --- | --- | --- |
| `task_started` | working | none |
| `task_complete` | idle | “Codex is ready” |
| `turn_aborted` | idle | none |
| *(any `*approval*` event, if present)* | needs approval | “Codex needs approval” |
| `request_user_input` | needs attention | “Codex needs attention” |

Because it reads logs (not the `notify` hook), it also catches the **“started working”**
edge that a hook can't, and it works on both the Codex **CLI** and the **Desktop** app.
Unknown events are ignored and unparsable lines are skipped, so it degrades gracefully
across Codex versions. Tested against `codex-cli 0.144.2`.

> If a future Codex release changes these events, please [open an issue](https://github.com/anes-laieb/codex-bar/issues/new/choose)
> with the Codex version, the behavior you observed, and safe reproduction details.

---

## Advanced: SwiftBar/xbar plugin (optional)

Prefer to render through [SwiftBar](https://github.com/swiftbar/SwiftBar) instead of a
standalone app? There's a plugin path that uses a small background watcher + a SwiftBar
plugin, installed with `./install.sh`. See [docs](docs/) and the scripts in `bin/` and
`plugins/`. Run **either** the app **or** the plugin. `install-app.sh` stops the plugin
path automatically. There's also an optional, best-effort `notify`-hook handler
(`./install.sh --with-notify-hook`) that edits `config.toml` **only** after backing it up
and preserving any existing hook.

---

## Requirements

- **macOS 13+**
- **Swift toolchain** (Xcode or `xcode-select --install`), only needed to build.
- **Codex CLI or Codex Desktop**, which Codex Bar watches.
- The macOS-provided `lsof` and `sqlite3` command-line tools.

## Privacy and network access

Session discovery and status processing happen locally. Codex Bar reads Codex's local
thread database and rollout logs, and stores its own preferences and recent-activity
history in macOS user defaults. It does not upload session contents.

When update checks are enabled, the app requests the latest release metadata from the
GitHub API. This is its only direct network request. You can disable automatic update
checks in **Quick Preferences**.

## Known limitations

- **Full menu bar:** Codex Bar is a normal menu-bar item; if your menu bar is packed
  (e.g. a notched Mac), macOS may hide it. Reveal it by ⌘-dragging items apart or with a
  menu-bar manager like [Ice](https://github.com/jordanbaird/Ice).
- **Log-format dependent:** it relies on Codex's rollout-log format, which may change
  across versions (see *How it works*).

## Repository layout

```
codex-bar/
├── install-app.sh          # one-command build + install of the app
├── app/
│   ├── CodexStatus.swift    # the whole app: log watcher + menu bar + window + notifications
│   ├── AppIcon.svg          # app icon (original sparkle mark)
│   ├── StatusAssets/        # app, idle-state, and animated working artwork
│   ├── Info.plist           # bundle metadata
│   └── build.sh             # compile -> "Codex Bar.app" (+ icon via built-in tools)
├── install.sh · uninstall.sh   # optional SwiftBar/watcher path
├── bin/ · plugins/ · tools/     # the SwiftBar/watcher implementation
├── docs/                        # architecture, development, and media guidance
├── CONTRIBUTING.md · CODE_OF_CONDUCT.md · SECURITY.md · SUPPORT.md
├── CHANGELOG.md · README.md · LICENSE · NOTICE
```

For implementation details, see [Architecture](docs/ARCHITECTURE.md). For local build
and verification guidance, see [Development](docs/DEVELOPMENT.md).

## Project policy and support

Issues are open for bug reports and feature requests. The project is **not accepting
code or documentation contributions at this time**, so please do not open pull requests.
Read [CONTRIBUTING.md](CONTRIBUTING.md) before participating, [SUPPORT.md](SUPPORT.md)
for help channels, and [SECURITY.md](SECURITY.md) for private vulnerability reports.

## License

[Apache-2.0](LICENSE) © the Codex Bar contributors. An independent, community project,
not affiliated with or endorsed by OpenAI; see [NOTICE](NOTICE).
