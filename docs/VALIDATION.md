# Local validation of 0.8

This repository starts from the prepared 0.8 source snapshot. Public packaging changes the build output directory and adds project license notices; the Swift app source is unchanged.

Verified locally on macOS / Apple Silicon:

- Compilation, strict ad-hoc signature verification and plist validation.
- Native window group movement, independent panel frame changes, independent player resize, hidden-panel behavior, group ordering over a separate window, floating/normal pin levels and sheet keyboard focus.
- A real mouse drag of the player moved all three windows by the same nonzero offset.
- Clicking the pin updated its accessible state and visual indicator.
- A native bitmap of a moderate FFT level contained green, yellow and orange bar pixels, with peaks disabled for the check.
- Classic `.wsz` rendering, transport/EQ coordinates, invalid archive rejection and restoration of the default interface.
- Playback/auth UI guards: double play during session installation, reset state, Space handling in a sign-in sheet, Google button and cancellation behavior.

The automation did not confirm an independent EQ mouse drag. Frame-independence checks passed, and the existing EQ header handler is unchanged. This is an unverified manual flow, not a passing mouse test.

A focused local review found an asynchronous native-drag lifetime bug and a sheet focus regression. Both were repaired and received targeted checks. A second whole-candidate review was not run; a clean final review is not claimed.

Audio, Chrome transport, sign-in, service requests, EQ, local decoder and skin parser source are unchanged from 0.7. Prior local tests covered five local formats, transport/end/replay, EQ response, stereo FFT, missing-file recovery and public YouTube streaming. That evidence does not establish behavior on every account or machine. Sign-in and liked-music UI were observed in the installed 0.7; the new 0.8 window checks did not use a real account.

All test playback was muted. No public binary release, notarization or automatic-update path has been verified.

## Run focused checks

After `./build.sh`, mount the generated DMG and copy the app to a temporary folder. Do not overwrite a running copy just to test it. The executable accepts these diagnostic flags:

```sh
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-group /tmp/retroamp-group.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-ui /tmp/retroamp-ui.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-display /tmp/retroamp-display.json
```

These launch native windows and can activate the app. Use a logged-in desktop session and a disposable app preference domain for repeated UI tests; window geometry and test display preferences can otherwise affect a copy with the same bundle ID.

For skin checks, use a skin you are licensed to use:

```sh
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-skin /tmp/retroamp-skin.json --skin-file /path/to/skin.wsz
```

Review the JSON assertions as well as the process exit code. Some diagnostic modes write failures to JSON and still terminate normally.
