# Changelog

## 0.10.0 — prepared for review

This update includes the local 0.9.x improvements since the published 0.8 source.

- Replace the continuous Chrome playback backend with an app-owned WebKit helper and native Core Audio routing. Chrome is still needed temporarily for a new Google sign-in.
- Keep the ten-band EQ, preamp and real FFT spectrum on the native audio path. Reduce repeated drawing and reuse bounded audio/analysis buffers. Restart the native engine on the next playback poll if a hardware-format interruption stops it, while retaining the muting capture tap.
- Add an independent VIDEO window synchronized to the current track, with AUTO / 720p / 1080p requests and actual decoded resolution. Audio songs can switch to their service-provided official video in the same player.
- Import nested album folders into a persistent local library; add favorites and YouTube Music likes.
- Add macOS media-command handling, classic Z/X/C/V/B controls, current-state indicators, visualizer settings and improved attached-window movement.
- Restore saved YouTube Music sessions across launches and updates. A changed ad-hoc signature can still require Keychain authorization; a still-valid saved session does not require repeating Google sign-in.
- Add a macOS build and isolated, silent native-DSP check to GitHub Actions.
- Bound helper IPC writes and test-runner subprocesses; preserve the final shutdown acknowledgement when draining the background writer.

Local physical-footprint samples: 632–687 MiB for YouTube Music audio, 45–54 MiB for local files, and about 996 MiB for visible 1080p VIDEO. These are short samples including owned WebKit processes, not guarantees. See [validation notes](docs/VALIDATION.md) for conditions, known baseline lamp-test failures and manual checks.

The app remains experimental and ad-hoc signed. Developer ID signing, notarization and automatic updates are not configured. Exact WebKit process identification uses read-only SPI; unofficial Google interfaces can change.

## 0.8.0

Initial published macOS source, classic Winamp-style windows and `.wsz` skins, local audio and YouTube Music integration. Licensed under MIT.
