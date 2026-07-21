# Capturing README media

The README uses a branded hero, a sanitized application-window preview, and the status
artwork bundled with Codex Bar. Keep those assets accurate, private, and reasonably small.

## Application preview

1. Build the exact version being documented with `sh app/build.sh`.
2. Launch the built bundle and arrange the window in the appearance you want to publish.
3. Capture the window at Retina resolution with macOS Screenshot (`Shift-Command-5`).
4. Review every task title, project name, path, model name, notification, and activity
   entry before committing the image. Codex session text can be private.
5. Replace live task names with clearly fictional demo copy or blur them completely.
6. Save the final image as `docs/assets/app-window.png` and update
   `docs/assets/README.md` if the preparation method changes.

The final preview should show the real application structure and controls. Do not add a
feature to the screenshot that the documented version does not implement.

## Animated status capture

The README currently embeds the app's bundled working animation directly. If a short
menu-bar recording would explain a future interaction better:

1. Press **Shift-Command-5** and choose **Record Selected Portion**.
2. Record idle → working → attention or completion in a tight menu-bar region.
3. Keep the final animation between five and eight seconds and below roughly 3 MB.
4. Export at 12–15 fps and a width appropriate for the README.

For example, with `ffmpeg` installed:

```sh
ffmpeg -i ~/Desktop/codex-bar.mov \
  -vf "fps=12,scale=720:-1:flags=lanczos" docs/assets/menu-bar-demo.gif
```

## Hero artwork

The hero is decorative product artwork, not a screenshot. Keep the application icon
recognizable, avoid fake interface claims and embedded text, and label the image as an
illustration in both the README and `docs/assets/README.md`.
