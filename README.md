# Codex Bar

A tiny macOS **menu-bar app for the [Codex CLI](https://github.com/openai/codex)** —
so you always know, at a glance, whether Codex is **working** or **waiting for you**,
and you get a **native notification** the moment a turn finishes. Like the
"your agent is done" feedback in Claude Code, but for Codex.

![Codex Bar — menu-bar states, window, and a turn-complete notification](docs/demo.svg)

> The image is a mockup — to drop in a real screen recording, see [docs/CAPTURE.md](docs/CAPTURE.md).

---

## What it does

- **A sparkle in your menu bar, colored by state** — 🟢 green = idle · 🟡 amber = working · 🔴 red = needs approval.
- **A cycling word while it works** (`Thinking… · Cooking… · Prompting…`), at fixed width so it never jitters.
- **A notification when a turn completes** — *“Codex — ready for you”* with Codex's last message.
- **A window + Dock icon** — click the app (or its menu) to see the live turn: elapsed time, project, model · effort, approval policy, and the last message.
- **Completion sound** you can toggle on/off, and **Launch at Login**.
- **No config, no daemon, no `notify` hook.** It just reads Codex's own session logs, so it can't break your Codex setup and never edits `~/.codex/config.toml`.

---

## Install (one command)

```sh
git clone https://github.com/anes-laieb/codex-bar.git && cd codex-bar && ./install-app.sh
```

That builds **Codex Bar.app**, puts it in `/Applications`, and launches it. A sparkle
appears in your menu bar and a window opens. Tick **Launch at Login** so it's always there.

**Requirement:** Apple's Swift toolchain (already present if you have Xcode; otherwise
run `xcode-select --install` once). macOS 13+.

That's it — no Homebrew, no extra apps.

---

## Using it

| Menu-bar sparkle | Meaning |
| --- | --- |
| 🟢 green | **idle** — Codex is waiting for you |
| 🟡 amber + cycling word | **working** — a turn is in progress |
| 🔴 red | **needs approval** — Codex is waiting on an approval (if your Codex version emits one) |

- **Click the sparkle** for a quick menu (live status, sound toggle, Launch at Login, quit).
- **Click the Dock icon** (or "Open Codex Bar Window") for the full window.
- When a turn ends you get the **notification** (with a sound, unless you turn it off).

### Uninstall

Quit it from its menu (or the window), then drag **`/Applications/Codex Bar.app`** to the Trash. Nothing else is left behind.

---

## How it works

Codex writes a JSON log for every session under `~/.codex/sessions/**/rollout-*.jsonl`.
Codex Bar tails the most-recently-active one, maps its events to a state, and updates the
icon + notifications:

| Codex log event | State | Notification |
| --- | --- | --- |
| `task_started` | working | — |
| `task_complete` | idle | ✅ “Codex — ready for you” |
| `turn_aborted` | idle | — |
| *(any `*approval*` event, if present)* | needs approval | ✅ “Codex needs approval” |

Because it reads logs (not the `notify` hook), it also catches the **“started working”**
edge that a hook can't, and it works on both the Codex **CLI** and the **Desktop** app.
Unknown events are ignored and unparsable lines are skipped, so it degrades gracefully
across Codex versions. Tested against `codex-cli 0.144.2`.

> If a future Codex renames these events, edit the small sets at the top of
> [`app/CodexStatus.swift`](app/CodexStatus.swift) (`task_started` / `task_complete` /
> `turn_aborted`) and rebuild. PRs welcome.

---

## Advanced: SwiftBar/xbar plugin (optional)

Prefer to render through [SwiftBar](https://github.com/swiftbar/SwiftBar) instead of a
standalone app? There's a plugin path that uses a small background watcher + a SwiftBar
plugin, installed with `./install.sh`. See [docs](docs/) and the scripts in `bin/` and
`plugins/`. Run **either** the app **or** the plugin — `install-app.sh` stops the plugin
path automatically. There's also an optional, best-effort `notify`-hook handler
(`./install.sh --with-notify-hook`) that edits `config.toml` **only** after backing it up
and preserving any existing hook.

---

## Requirements

- **macOS 13+**
- **Swift toolchain** (Xcode or `xcode-select --install`) — only needed to build.
- **Codex CLI or Codex Desktop** — that's what Codex Bar watches.

## Known limitations

- **Full menu bar:** Codex Bar is a normal menu-bar item; if your menu bar is packed
  (e.g. a notched Mac), macOS may hide it. Reveal it by ⌘-dragging items apart or with a
  menu-bar manager like [Ice](https://github.com/jordanbaird/Ice).
- **One session at a time:** the indicator tracks the most-recently-active Codex session.
- **Log-format dependent:** it relies on Codex's rollout-log format, which may change
  across versions (see *How it works*).

## Repository layout

```
codex-bar/
├── install-app.sh          # one-command build + install of the app
├── app/
│   ├── CodexStatus.swift    # the whole app: log watcher + menu bar + window + notifications
│   ├── AppIcon.svg          # app icon (original sparkle mark)
│   ├── Info.plist           # bundle metadata
│   └── build.sh             # compile -> "Codex Bar.app" (+ icon via built-in tools)
├── install.sh · uninstall.sh   # optional SwiftBar/watcher path
├── bin/ · plugins/ · tools/     # the SwiftBar/watcher implementation
├── docs/                        # demo image + capture guide
├── README.md · LICENSE · NOTICE
```

## License

[Apache-2.0](LICENSE) © the Codex Bar contributors. An independent, community project —
not affiliated with or endorsed by OpenAI; see [NOTICE](NOTICE).
