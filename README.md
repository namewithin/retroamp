# Retroamp

A compact macOS music player by [namewithin](https://github.com/namewithin), with a Winamp 2-inspired interface. Plays local files and connects to your YouTube Music library.

![Retroamp player — example spectrum](docs/images/player.png)

**Experimental, version 0.8.0.** The interface is currently mostly Ukrainian. The app is native AppKit; YouTube playback uses an app-owned Chrome process.

## Features

- Three separate windows: player, equalizer, playlist. Drag the player header to move the group; move and resize the other panels independently.
- Clicking a panel brings the visible group forward. The small pin button keeps the windows on top.
- Ten-band EQ, preamp, presets and an FFT spectrum from the audio signal.
- Click the clock to switch elapsed/remaining time. Click the spectrum to switch narrow/wide bars. Long titles scroll in the player.
- Local playback through AVAudioEngine. WAV, MP3, AAC/M4A, FLAC and AIFF have been tested.
- Classic rectangular Winamp 2 `.wsz` skins. Original Winamp skins are not bundled.
- Google sign-in and access to your YouTube Music library, without manually copying request headers.

## Build

Requires macOS 14 or later and Xcode Command Line Tools. Local runtime testing has been on Apple Silicon. Google Chrome at `/Applications/Google Chrome.app` is required for YouTube Music, but not for local audio.

```sh
git clone https://github.com/namewithin/retroamp.git
cd retroamp
./build.sh
```

The script builds for the host architecture and creates `dist/Retroamp-0.8.0.dmg`. It uses the macOS frameworks and system zlib; no package manager or API key is required. Set `RETROAMP_OUTPUT_DIR` to choose another output directory.

The build is ad-hoc signed. Developer ID signing, notarization and automatic updates are not configured. If macOS blocks a locally built app, use the normal macOS approval flow after reviewing the code.

## Use

- **Local music:** press ⌘O or the eject button; select files, or drop them onto a panel. Double-click a playlist entry to play it. Space pauses/resumes when you are not editing text. Initial volume is 15%.
- **YouTube Music:** click GOOGLE, then “Увійти через Google”. Complete sign-in and any MFA in the browser window; the app validates the session and loads the library. LIB opens library sections.
- **Skins:** use “Вигляд → Завантажити скін Winamp 2…”, or drop a `.wsz` file. “Основний скін Retroamp” restores the built-in look. “Зібрати вікна” restores the compact arrangement.

## How YouTube Music works

This is an **unofficial integration**, not the official Google OAuth API. Sign-in opens a separate temporary Chrome profile. The app captures the YouTube session, stores it in macOS Keychain and restores it into its own streaming browser. It does not read your regular Chrome or Safari profiles. No browser extension is required.

Ads and subscription restrictions remain in effect. Google changes can break sign-in, library requests or playback. Changing an ad-hoc build can require signing in again. Do not include cookies, session headers or account screenshots in bug reports.

## Limits and verification

Modern `.wal`/XML skins, arbitrary region masks, custom cursors and shade mode are not implemented. Google library access and playback can vary with account state and ads. Broader testing of macOS window behavior is welcome.

The native group/pin tests and a real mouse drag of the player passed locally. An independent EQ mouse drag was not confirmed by the automation; its frame-independence test passed. See [validation notes](docs/VALIDATION.md) for the exact scope and available checks.

## License and credits

[MIT](LICENSE), copyright 2026 namewithin. See [NOTICE.md](NOTICE.md) for third-party attribution.

Classic sprite coordinates were checked against [Webamp](https://github.com/captbaritone/webamp), which is MIT licensed. Its notice is preserved. The default interface and app icon are drawn assets from this project. Imported skins retain their own licenses; the project's MIT license does not grant rights to Winamp artwork or branding. Retroamp is not affiliated with Winamp or Google.
