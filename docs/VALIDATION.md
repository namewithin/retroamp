# Local validation of 0.10.0

This local candidate replaces the continuous Chromium playback backend with a bundled WebKit helper, an exact-process Core Audio tap, bounded C PCM queues, AVAudioSourceNode, native 10-band EQ and a persistent native FFT. The same stream supplies VIDEO; there is no second audio player. Existing Keychain/session APIs and Google sign-in are retained. Chrome is still used temporarily for a new Google sign-in; it is not required for restored-session playback or local files. This is an experimental personal client, not an App Store release.

## Memory and CPU

Measured on this Apple Silicon Mac on 2026-10-15 with speaker output muted and without personal credentials. The reported memory is **physical footprint in MiB**, including compression/graphics allocations, not summed process RSS. The host, helper and exact native-reported WebKit GPU/WebContent processes were recorded; networking/spare WebContent attribution additionally uses matching process launch/exit lifecycle. Unrelated iOSSupport WebKit processes were excluded. All collected app processes exited after the scenarios. System services and WindowServer are outside the totals. Phases ran approximately 16 seconds, sampled at 1 Hz; CPU uses cumulative time deltas after the first 3 seconds and 100% means one logical core. Other host load was uncontrolled.

| State | Total physical footprint | CPU, percent of one core |
| --- | ---: | ---: |
| Fresh / session-only idle | 23 MiB | 0.0% |
| YouTube Music audio | 632–687 MiB | 11–16% |
| YouTube Music paused | 401–446 MiB | 5–6% |
| Local AAC playing | 45–54 MiB | about 4% |
| Local AAC paused | 45–53 MiB | 0.0% |
| 1080p VIDEO visible, final native image renderer | 996 MiB | 42% |
| 1080p VIDEO paused, final native image renderer | 509 MiB | 4.7% |

The audio/local ranges cover two full 11-phase runs. The final two-phase VIDEO run used the same public clip ID, 800×620 window and actual 1552×1080 decoded frames. It delivered 10.3 fps on that run; the export cap and quality were not lowered. It produced 152 real native spectrum callbacks in 16 seconds with zero ring overflows. Earlier runs varied in frame rate and service/ad readiness, so these are measured samples, not guarantees.

Native partial redraw and layer backing reduced the audio-playing host from 277 MiB to about 28 MiB. Local playback releases the streaming host, helper and WebKit cohort. Replacing custom NSImage drawing with a native NSImageView, disabling transient JPEG image caching and using a per-frame autorelease pool reduced the visible-VIDEO host from 452 MiB to 320 MiB in the recorded samples. The rest is primarily WebKit page/decoder/graphics memory. Attempting to order the invisible source window out did not save memory and was reverted; its alpha-zero, non-interactive window remains attached so WebKit initializes media reliably.

The earlier standalone WebKit/native-audio prototype used about 925–948 MiB. The previous Chrome control used about 891 MiB during audio and 613 MiB during its VIDEO sample. Those are separate workloads/runs, not a controlled comparative benchmark; this migration does **not** establish a universal video-memory improvement. In particular, visible 1080p can still approach 1 GiB. Earlier 1.6–1.8 GiB figures were summed RSS and cannot be compared directly to the physical-footprint table.

## Pre-merge subagent review (2026-10-16)

Three independent read-only subagent reviews covered native capture/DSP, stream/auth/VIDEO, and local library/UI/build delivery at `58571812744aae8cc3554d33d957683ae4a0f8b1`. One P2 was confirmed: hardware format changes can stop AVAudioEngine while the process tap remains active, but the streaming poll previously returned without restarting the engine. The repair makes native start idempotent and checks it during the existing owned-source polling path; no new notification callback or capture teardown is introduced.

An integrated regression deliberately stops only the test DSP engine during real muted WebKit PCM playback. Before repair, the YouTube clock advanced to 12.84 seconds with zero new native spectrum frames and the tap still active; the test failed. It requires automatic restart, new FFT frames, retained tap and zero native output volume. This simulates the documented engine interruption without changing the user's output device. It does not establish real hardware route/sample-rate switching or the full device matrix.

## Reproducing the offline DSP check

```sh
RETROAMP_APP_DIR=/private/tmp/retroamp-build RETROAMP_SKIP_DMG=1 ./build.sh
python3 scripts/check-offline.py --app /private/tmp/retroamp-build/Retroamp.app --output /private/tmp/retroamp-audio.json
```

The script copies and re-signs the app with fresh QA preference domains, validates individual assertions and rejects empty, shortened or contradictory results. The default suite checks native DSP. Use `--suite all` to run native DSP (16 assertions), synthetic session handling (13) and local library/media-command/visualizer/window behavior (40). Every app process is muted; personal Keychain/session startup is bypassed. The session reader and YouTube-like endpoint use synthetic fixtures. No Google account, system-audio capture or live service is used.

GitHub Actions builds on Apple Silicon and Intel, verifies app/helper signatures, tests the result validator and runs all 69 app assertions for every PR opening/reopening/new commit and push to `main`. It uploads per-suite JSON, logs and synthetic UI renders, including on failure. Its actual result must be read on the PR. Real Google playback, native process-tap routing and hardware keys/output-device changes remain separate checks requiring a suitable environment and permissions.

## Behavior and safety checks

The actual production native DSP passed 16 offline checks: EQ boost/cut/bypass/preamp, real FFT peaks, stereo separation/order, 1% source gain compensation, ring wrap/overflow/underrun and exact-process filtering. The integrated muted stream check passed real WebKit-to-native PCM, live EQ changes, seek/pause/resume, full document navigation rebuilding its exact tap, cookie scope/security/expiry migration, non-YouTube cookie rejection, failed-mute shutdown handling and terminal session-restore/playback barriers. Full navigation, failed mute and a pending restore were concrete independent-review findings and received behavior regressions.

The service helper is hash-verified, has bounded line framing and communicates over private parent/child pipes, without a DevTools TCP listener. The tap selects only the exact reported owned GPU process and revalidates its HAL identity before termination; it does not capture other apps or microphone input. Direct source media is muted until capture is established and limited to 1%, with gain restored before native EQ. Shutdown retains the muting tap until source silence/termination is confirmed. macOS still controls System Audio Recording permission. Exact GPU lookup uses read-only WebKit SPI and can fail on future macOS versions.

The final VIDEO check passed 22 assertions. Its hide-audio regression now waits for the restarted fixture clock to advance before measuring the same original time-progress assertion; direct media-clock diagnostics confirm playback continues while capture is off. The initial failing timing/timeout results are retained.

The retained session-storage check passed 13 assertions, the quality/counterpart check passed 23, and the 0.9 feature suite passed folder imports, favorites, media-command handlers, docking and spectrum behavior. A focused independent local review completed with no findings after the three repairs (confidence 0.88, manifest of 24 files). The review engine identified itself as codex; provider, model and endpoint were unavailable. A later narrow presentation review was clean; the ineffective source-window hiding branch was subsequently removed. The final NSImageView renderer was checked through production VIDEO behavior, native screenshot inspection and the focused real-public-1080p resource run.

The transport suite retains the same five baseline green-pixel lamp assertion failures from 0.9.4/0.9.5. Other transport assertions passed. This is not an all-green full suite. Physical hardware media keys, output-device switching, long-duration capture clock drift remain separate manual checks. After installation, saved-session restore and real personal-library loading were verified without repeating Google sign-in. A library track advanced with a responsive native spectrum and no Chrome playback process; the user confirmed audible speaker sound. Automated checks use zero speaker output and do not prove audible speaker playback. These local checks do not establish GitHub CI or canonical PR review results. No release, notarization or automatic updater is claimed.

Raw evidence and sampler source are retained in the local `outputs/Retroamp-0.10.0/checks` delivery folder, including failed diagnostic attempts. Source baseline is main/origin main `d5aa638914647a44c45915453b30364e2bbfb8e7`, fetched again on 2026-10-15. The starting local 0.9.5 source had existing uncommitted changes; this candidate preserves them. Publication and remote review status belong to the GitHub PR, separately from these local results.

# Earlier local validation of 0.9.5

The 0.9.5 candidate reduces idle/paused work without changing the interface, spectrum settings, video quality or frame export limit. It stops unneeded native animation and local audio timers, pauses the native audio engine, coalesces Now Playing/state publications, slows paused YouTube/VIDEO checks and suspends the paused WebAudio graph. Chrome no longer prewarms on launch/session install. Release compilation now uses standard Swift `-O -whole-module-optimization`; the before build used the prior unoptimized flags. The figures below reflect that complete change, not an isolated microbenchmark.

A cold-start check exposed polling during page bootstrap/navigation. Polling now waits for stream setup, preparation avoids a redundant Music homepage navigation, and transient navigation/response-timeout errors can retry only during the existing bounded loading period. A closed connection or other error still fails. This final candidate completed every public-stream measurement phase; low idle CPU from earlier failed attempts is not treated as proof of working playback.

## Resource measurements

Measured locally on the same Apple Silicon Mac on 2026-10-15, with muted output, separate QA preference domains, the same public track/video IDs and a real encoded local AAC fixture. Each phase ran about 16 seconds; CPU uses cumulative process-time deltas from 1Hz `ps` samples, excluding the first 3 seconds. The total includes the native app and its owned Chrome descendants. **100% means one logical CPU core.** WindowServer, system audio and system GPU energy are not included. Unrelated host load was high; these short measurements indicate direction and scale, not precise battery life or statistically controlled results.

| State | 0.9.4 total CPU | 0.9.5 total CPU |
| --- | ---: | ---: |
| Fresh idle | 3.9% | 0.09% |
| Session installed, no selected stream | 8.2% | 0.00% |
| YouTube audio playing | 19.9% | 14.10% |
| YouTube audio paused | 17.1% | 2.55% |
| 1080p stream, VIDEO hidden | 19.4% | 17.03% |
| 1080p VIDEO visible | 49.3% | 45.17% |
| 1080p VIDEO paused and visible | 22.9% | 4.33% |
| Local AAC playing | 9.1% | 3.48% |
| Local AAC paused | 9.9% | 0.00% |

The visible VIDEO copied 1552×1080 frames in both builds: 16.1 fps before, 16.37 fps after. Quality and frame delivery were not reduced to obtain the savings. Ads remained enabled; the after readiness check waited 32.3 seconds through ads and required a non-ad playing source before the timed playback phases. It does not measure startup latency independently of ads.

Fresh/session-only idle now has one native process and about 82 MiB sumRSS; previously session install started 12 processes at about 1711 MiB sumRSS. A paused local file uses about 106 MiB sumRSS in both builds. Once YouTube has been used, its browser is retained for quick resume: the after audio/video phases still used roughly 1.6–1.8 GiB **summed process RSS**, with 11–12 processes. Summed RSS can count shared pages more than once and is not unique physical memory. This change chiefly reduces wasted CPU; it does not eliminate Chromium's memory cost. Local playback releases the streaming backend.

The before sampler did not produce enough eligible samples for paused-hidden VIDEO and stopped YouTube; no before/after claim is made for those states. Final after-only results were 1.37% and 3.08% of one core respectively. During diagnosis, two abandoned muted QA browser trees from earlier checks were identified by exact owned temporary profiles and closed; their 18 processes had 1663 MiB summed RSS. This cleanup is separate from the app optimizations; no general crash/orphan cleanup feature is claimed.

Evidence is retained in the local delivery folder `outputs/Retroamp-0.9.5/checks`: raw native phase results, OS samples and sampler source. All 11 final phases completed, including local playback/pause after streaming. Earlier failed runs are retained as diagnosis, not accepted measurements.

## Regression checks

The final lifecycle check covers idle timer sleep, scrolling-title wake, minimize/unminimize, unchanged paused metadata, immediate seek/resume publication, real local AAC pause/resume/seek/stop/restart, natural short-file queue/repeat transitions, paused media-command availability after repeat changes and foreground/background imports, pause before first signal, and WebAudio suspend/resume. The initial independent local review found an old-file state emission during local-track handoff, stale media-command availability after queue changes, and an ad-permitting final cold-stream assertion. These were repaired with behavior regressions; the final review result is recorded in the delivery evidence.

The packaged executable passed all 22 lifecycle assertions and all 23 HD-quality/counterpart assertions in a separately re-signed, muted QA app. The production-video, WebAudio EQ/spectrum and 0.9 feature checks also passed. A final narrowly scoped independent repair review completed with no findings (confidence 0.98), reusing the prior reviews for unchanged code. The transport suite retains the same five green-pixel lamp failures recorded for 0.9.4; every other transport assertion passed. Physical hardware media-key delivery remains a separate manual check. The quality/counterpart fixture initially ended its simulated ad on a fixed wall-clock schedule, before the slower paused poll had completed the first lookup. It now observes the production switch rejection while the ad is present before ending the ad, retaining the requirement for a second lookup and correct official video. The initial failing result is retained.

## Earlier 0.9.4 validation

The 0.9.4 candidate adds a persisted AUTO / 720p / 1080p selector and actual decoded-resolution status in VIDEO. The internal YouTube player's quality range is requested; no guarantee is inferred from the menu selection. Frame export now retains up to 1920×1080 pixels, preserving aspect ratio and never enlarging the source. The serialized capture loop remains unchanged.

For audio songs, the authenticated Music `next` response is inspected for an explicit audio/video counterpart. Only a wrapper containing the requested recording and a video-typed target is accepted. A single existing media element switches recording using the service's segment map and the position at the time of switching. The original queue/favorite identity is retained. No counterpart search blocks audio startup. No pairing, expired authentication, cancellation or a stale lookup leaves the audio path intact; clip failure restores audio. Closing VIDEO stops capture and retains the chosen recording.

Evidence for this batch is recorded in `outputs/Retroamp-0.9.4/checks` in the local delivery workspace. Focused integration checks cover the authenticated endpoint and target, reverse segment mapping, unrelated/absent pair rejection, delayed lookup after a seek, preserved pause, new-track cancellation, clip-error fallback, one media element, HD frame dimensions, popup quality requests, unavailable-quality wording and paused frame refresh after a resolution change. Public stream checks inspect both source and copied-frame dimensions for 720p and 1080p, a paused quality request and resumed decoding. All automated playback is muted, with separate test preferences and no personal credentials.

A further muted public-stream check used the production JavaScript and a previously observed official pair: Take Back the Power audio at 20.100 seconds switched to its video at 20.081 seconds, remained paused and retained one media element. This checks the real browser recording switch; it does not claim that an unauthenticated `next` request returned the pair.

The ad-race regression failed before repair and passed afterward. Ads no longer overwrite the recording position, an ad interrupting lookup permits retry afterward, and a recovered paused audio source remains ready beyond the real 30-second startup deadline.

The transport regression returned the same five failing green-pixel lamp assertions on both installed 0.9.3 and 0.9.4 in separate QA domains. All other transport assertions passed; the drawing/transport code is unchanged in this delta. These results are retained instead of reporting that suite green.

The README HD pictures are real native VIDEO window captures from the public clip, not generated mockups. Service quality methods and counterpart response fields are unofficial and can change. Counterpart availability depends on song, account/subscription and region; no exhaustive live account/catalog matrix has been tested. The account pairing parser uses the observed Music wrapper/segment schema; the full switch is verified with encoded video/audio integration fixtures. Public quality tests are unauthenticated. This does not claim live personal-account counterpart verification, CI, publication, notarization or automatic updates.

## Earlier 0.9.3 validation


The 0.9.3 candidate adds an optional fourth native VIDEO window. It receives decoded pictures from the existing Chromium video element through an offscreen canvas, never starts another media element/audio graph/browser, and does not change the YouTube page layout. In that version, pictures were capped at 960 pixels wide and approximately 24 polling cycles per second; service quality and actual media frame rate still apply. Browser CORS/security restrictions are retained and reported as a video-only error.

Verified for 0.9.3:

- The production browser played an encoded moving MP4 fixture with audio muted. Native frames changed over time; pause, seek while paused, next, stop and caption/clock synchronization passed. The DOM contained exactly one media element.
- Hiding VIDEO stopped frame delivery while playback advanced, reopening resumed pictures, and reopening while paused requested the current frame without resuming audio. Video-only failure preserved audio playback and could recover after hiding/reopening. Switching to a local track cleared the image and showed a placeholder.
- A delayed-frame regression reproduced overlapping evaluations across rapid hide/reopen revisions. The repaired scheduler awaits the previous in-flight request, coalesces cancelled intermediate revisions and keeps maximum frame-request concurrency at one. The same test failed before the repair and passed afterward.
- Four-window membership, independent video move/resize and canvas layout, docked group movement, detached independence, pin inclusion and focused shortcuts passed through the production native classes. VIDEO uses the unchanged shared drag/resize machinery previously checked with real mouse input. VID and Cmd4 opening were observed through CUA in a distinctly named test copy.
- A public, unauthenticated YouTube live clip produced video-only native pictures, matched source aspect ratio and paused with the same media clock, with no speaker output. A real clip image was inspected. Earlier page-capture/layout experiments showed website chrome and were discarded; only direct media-frame copying remains.
- Production WebAudio EQ gain/cut/preamp/bypass, stereo preservation and spectrum checks passed. Native transport/LED/keyboard regression checks passed. Keychain/auth storage and local decoding are unchanged from 0.9.2.

All automated media tests were muted and used test-only preference domains without personal account access. A muted interactive preview left open briefly confused the user; it was closed, the installed app resumed at 5 percent and the user confirmed sound. Diagnostic headers now say TEST / MUTED and automated check windows ignore mouse input. See the local delivery incident record for details.

In 0.9.3, tracks without video showed an audio-only message and no alternate official clip was searched. Frame export may be unavailable for a restricted video while audio continues. No exhaustive account/region/ads test, public release, CI, updater or notarization was performed.

## Earlier 0.9.2 validation

The 0.9.2 candidate removes the executable-hash gate on saved YouTube Music sessions and adds an explicit restore action for macOS Keychain authorization after an ad-hoc update. It retains the original Keychain item/service/account, native access controls and Google validation. Sessions are not deleted by a failed read or restore. No extension or ordinary browser-profile access was added.

Verified for 0.9.2 with synthetic credentials:

- A real test-only Keychain item was saved, read and restored in a separate app process. A stale build-hash marker no longer blocks the production read path.
- Changing and re-signing the test app produced a different executable hash. The new build reported that macOS authorization was required, without opening a browser or a Keychain prompt. The original authorized test app could still read the exact saved session afterward, then removed its own test item.
- The initial update test exposed that LAContext alone does not suppress prompts for existing file-based macOS Keychain items. The repaired code temporarily sets the legacy process interaction policy on MainActor and restores it after the synchronous read. The real update test then completed without a prompt. The SDK deprecation warnings for this legacy compatibility API are expected; migrating to a different Keychain type is outside this change.
- Missing items, denied/cancelled access and malformed data are distinguished. Explicit restore enables native authorization; startup disables it. Tests check that the interaction policy is restored after success and errors. Connection-panel cancellation and keyboard exclusions remain checked.

No personal Keychain session was used by these tests. Real Google expiry/revocation still requires sign-in, and a changed ad-hoc identity can still require user approval in macOS. Real account restoration is a separate installed-app check; a permission prompt must be completed by the user.

## Earlier 0.9.1 validation

The 0.9.1 candidate adds visible transport/mode indicators and focused Z/X/C/V/B shortcuts. It remains an uncommitted local candidate based on `d5aa638914647a44c45915453b30364e2bbfb8e7`. The installed personal app is 0.9.0; it was not replaced or restarted for these checks.

Verified for 0.9.1 on macOS / Apple Silicon:

- `--check-transport` passed the physical Z/X/C/V/B and Space mapping, Ukrainian-layout positions, text/modifier/repeated-key/sheet/settings exclusions, play/pause/stop states, LED bitmap assertions, EQ processing and panel visibility states, repeat-one labels and shuffle order restoration.
- Previous rewinds a track beyond three seconds, then selects the preceding track on a second press. A test suppressing asynchronous state delivery confirms rapid double-Previous works. Rewinding a paused local track preserves pause. Stopped and naturally ended tracks can be replayed.
- Real native X/C/Z/Z/B/V keystrokes in a disposable app were checked through CUA, with volume at zero. The displayed clock returned to zero, the second Z selected the preceding fixture, and the EQ ON/OFF LED changed visibly. Classic `.wsz` EQ sprites and default panel renders were also checked.
- Independent local review identified a completed YouTube-stream end latch that seek did not clear. A production-browser regression reproduced the defect before repair and passed afterward: a muted real HTMLMediaElement reaches its end, seeks to zero while paused, reports `ended: false`, and can reselect the original track after a simulated YouTube auto-advance. The production WebAudio EQ/stereo/spectrum assertions passed in the repaired build.

No real Google account or real-song playback was used for these new checks. Physical hardware media keys remain unverified; their Previous handler shares the checked behavior. The earlier 0.9 evidence below covers unchanged functionality.

## Earlier 0.9 validation

The 0.9 candidate adds recursive album-folder import, a persistent local library and favorites, YouTube Music likes, macOS Now Playing/media commands, edge docking and visualizer settings. The source base is GitHub main at `d5aa638914647a44c45915453b30364e2bbfb8e7`; the changes have not been committed or published.

Verified on macOS / Apple Silicon:

- Fresh compilation, DMG creation, strict ad-hoc signature verification and plist validation.
- Nested album-folder scanning, natural filename ordering, ignored cover images, cyclic symlink exclusion, duplicate roots/imports, empty/missing folders, visible playable rows and local library/favorites persistence.
- Real macOS folder picker imported two WAV tracks. Restarting the disposable test app restored both in the visible playlist. Clicking `+` saved the currently playing local track and changed its indicator to a check mark.
- Production local playback responded to the media-command handler's pause, toggle, seek, next and previous commands. macOS Now Playing metadata was registered. No-source commands were rejected. Physical hardware-key delivery was not verified: the UI automation does not support that key.
- The authenticated YouTube `like/like` request, video target, session rejection and unsigned-in rejection passed with a URLProtocol fixture. A real account's liked songs were not modified or verified during these checks.
- Player dragging moved all three transitively attached panels; a detached panel stayed independent. A real CUA mouse drag moved all three panels by the same nonzero offset. Independent move/resize, hidden-panel behavior, group ordering, pin levels and sheet focus checks passed.
- Existing clock, marquee, spectrum-width, classic `.wsz` rendering/coordinates, malformed-skin and auth-UI regression checks passed.
- A native FFT tone had a distinct frequency peak rather than saturating all bands. Display attack/decay, pause decay and sensitivity changes passed. The settings window and its real sensitivity slider were checked visually and through accessibility state.
- The production WebAudio graph passed EQ gain/cut/preamp/bypass, opposed stereo preservation, spectral contrast and loud/quiet amplitude-response checks. These tests produced no speaker output. They do not establish real-song startup latency or behavior on every YouTube account.

All test playback was muted or at zero volume. The installed 0.7 app and its personal Google session were not replaced or restarted for testing. Local decoder coverage for WAV, MP3, AAC/M4A, FLAC and AIFF comes from the earlier unchanged decoding path; the new media-command/folder checks used WAV fixtures.

No CI, public binary release, notarization or automatic-update path has been verified. Imported file paths are stored locally; moving or deleting a source file requires adding its new location again.

## Focused checks

After `./build.sh`, mount the DMG and use a disposable app bundle identifier/preference domain. Do not overwrite or restart a running personal copy just to test it. These diagnostic modes can activate native windows and change test-domain preferences:

```sh
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-v09 /tmp/retroamp-features.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-session-storage /tmp/retroamp-session-storage.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-video /tmp/retroamp-video.json --video-fixture /path/to/moving-fixture.mp4
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-public-video /tmp/retroamp-youtube-video.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-public-hd /tmp/retroamp-hd.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-video-quality /tmp/retroamp-quality.json --video-fixture /path/to/1080p.mp4 --audio-fixture /path/to/audio-only.m4a
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-transport /tmp/retroamp-transport.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-audio /tmp/retroamp-web-audio.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-group /tmp/retroamp-group.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-ui /tmp/retroamp-ui.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-display /tmp/retroamp-display.json
/path/to/Retroamp.app/Contents/MacOS/Retroamp --quiet --check-skin /tmp/retroamp-skin.json --skin-file /path/to/skin.wsz
```

Inspect the JSON assertions, not just the process exit code. Some diagnostic modes write failed assertions and still terminate normally.
