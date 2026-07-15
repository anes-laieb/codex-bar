# Capturing the demo GIF

`README.md` shows [`demo.svg`](demo.svg) as a placeholder mockup. Replace it with
a real recording of your menu bar so people can see it move.

## Quick way (built-in, no installs)

1. Start a Codex turn so the indicator goes 🟡, and have a completion ready.
2. Record a small region around the menu-bar icon:
   - Press **⇧⌘5**, choose **Record Selected Portion**, draw a thin box over the
     icon (and optionally the notification area), click **Record**.
   - Capture: idle 🟢 → start a turn (🟡) → completion banner + back to 🟢.
   - Stop from the menu bar (or ⇧⌘5 → stop). It saves a `.mov`.
3. Convert to GIF (pick one):
   ```sh
   # gifski (best quality):  brew install gifski
   gifski --fps 12 --width 720 -o docs/demo.gif ~/Desktop/Screen*.mov

   # or ffmpeg:  brew install ffmpeg
   ffmpeg -i ~/Desktop/Screen*.mov -vf "fps=12,scale=720:-1:flags=lanczos" docs/demo.gif
   ```
4. Point the README at it: change the image line to `![demo](docs/demo.gif)` and
   delete the placeholder note.

## Nicer way

[Kap](https://getkap.co) (`brew install --cask kap`) records a region straight to
GIF with trimming — no conversion step.

Keep it short (5–8s) and under ~3 MB so it loads fast on GitHub.
