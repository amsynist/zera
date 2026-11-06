# Zera v2 media

The v2 site and README use fresh native screenshots and recordings. Published media lives in site/assets/v2/. The 20-second, 60fps sharing-only film is made with the explicitly invoked brag/Hyperframes workflow; the longer walkthrough records every current primary screen. Demo tasks, files and artwork are fictional. Device framing is motion design; app surfaces are actual native captures. No voiceover is used.

## Reproduce the native walkthrough

On macOS 15 or newer, the existing opt-in fixture records the exact native fixture window with ScreenCaptureKit hardware encoding at requested 60fps. It emits `v2-source.mp4`, measured `v2-scenes.json`, `v2-recording.json` and fresh cropped native PNGs. The source is about 64 seconds, with roughly 58 actual frames per second. No per-frame CG/JPEG loop is used. All data is fictional; no microphone or real account/clipboard/calendar state is captured.

```sh
mkdir -p .build/v2-media-home .build/v2-media
CFFIXED_USER_HOME="$PWD/.build/v2-media-home" \
  ZERA_RENDER_SCREENS="$PWD/.build/v2-media" ZERA_V2_MEDIA=1 \
  swift test --filter ScreenRenderTests/testRecordV2Release
```

Normal `swift test` skips recording. The full kinetic walkthrough inserts a separate real native window-layout take and a closing overview, for 80.033 seconds at 60fps. Its 27 chapters have burned-in masked-word captions plus SRT/VTT. The sources play at actual speed without optical-flow synthesis. The water chapter uses a separately recorded native replacement: the opt-in fixture ticks its floating animation even when its recording window is occluded, so the reminder is visible rather than a blank wallpaper. Set `ZERA_V2_MEDIA_ONLY=water` with the same isolated-home capture command to reproduce that source. Nineteen native screenshots were refreshed from this same take, including the Zera v2 theme label. The dedicated sharing film remains separate.

## Record real window arrangements

The window-layout chapter in the existing film is historical. Its recorder, disposable window fixture and production arranger were removed together with Zera’s window manager. That chapter is not evidence of a feature in the current app. The retained source evidence and encoded proof under `docs/media/v2/walkthrough/` describe the earlier take. See [App Shortcuts](APP_SHORTCUTS.md) for the current optional Extra.

## Phone-to-Mac hero

The test-only Android instrumentation’s `-e media seed` mode imports original generated photographic PNGs from its private `files/media-assets` folder. The smoke-only fallback can create vector artwork; do not use that fallback for the photographic marketing take. The six photo prompts and local asset names are retained in docs/media/v2/photo-prompts.md. `-e media share` opens the real gallery photo and injects a real right-edge gesture. Mobile data was disabled on the disposable emulator. A local isolated Zera receiver listens on port 18989 and saves in a temporary inbox. The replacement uses host graphics on the disposable emulator and asynchronous gesture injection over a natural 1.1-second swipe, keeping Binder round-trip latency out of the touch cadence. `ScreenRenderTests/testRecordV2PhotoReceiver` (macOS 15+) uses ScreenCaptureKit file recording at requested 60fps, capturing only its clean fixture windows and the exact newly opened “Zera coast” Preview window. Other existing Preview windows are excluded. This replaces the old per-window CG/JPEG loop, whose roughly 8–10fps capture made the first film look choppy. The live-wallpaper Mac take records about 57fps throughout the film; the phone records about 53fps during its actual swipe. Static Android screens naturally use variable cadence. Exact source counts and intervals are retained in docs/media/v2/source-cadence.json. The photographic coast PNG was independently SHA-256 matched with the phone original (3,285,000 bytes). This is functional evidence, not a physical Samsung or router-throughput claim.

Raw phone/Mac starts and approach/release/save markers are recorded in the ignored media workspace. The current film uses an unchanged 20-second synchronized interval with both native recordings live for the entire film; no source speed-up or optical-flow frame synthesis is used. The native fixture wallpaper uses cached gradient layers and slow compositor translation. It never changes the user’s desktop. The moving wallpaper continues behind the real received photo through the closing beat. The overall presentation adds a full-frame flowing vector hex grid, hardware-attached Android/MacBook labels, kinetic captions and purposeful close-ups. An exact-original image bridges only the physical gap between the device frames. It never replaces native UI. There are no notch receipt, Agents or unrelated feature scenes in the sharing film. Large burned-in captions use masked word reveals and reading holds; purposeful continuous camera moves direct attention from phone to Mac. SRT and VTT sidecars retain the same caption timing.

## Publication files

- sharing.mp4 / sharing-poster.jpg — standalone sharing-only film, 20 seconds / 60fps, kinetic captions burned in and poster baked into frame zero.
- sharing.srt / sharing.vtt — caption sidecars for platforms and accessible players.
- wallpaper/zera-tidal-5k.jpg / .png — clean 5120×3200 exports of the native fixture wallpaper, without the notch, companion or app windows. The JPEG is the practical desktop download; PNG preserves lossless pixels.
- walkthrough.mp4 / walkthrough-poster.jpg — complete 80-second kinetic native screen flow, including real window arrangements.
- walkthrough.srt / walkthrough.vtt — 27 accessible full-tour caption cues.
- screens/*.webp — current app screens, cropped at their native island boundaries.
- media-provenance.json — source timing, fixture and verification summary, without private paths.

The build/composition workspace is ignored. Public storyboard, brief and share copy are retained under docs/media/v2/ for the release. Keep videos local until the requested publishing step.

Music: “Happy Beats / Business Moves Vol. 12” by Sascha Ende, ende.app, CC BY 4.0. Sparse UI accents are CC0 from the brag bundled library where used. These are not covered by the repository’s MIT code license. Zera’s original art remains under LICENSE-ASSETS.md.

## Walkthrough completion

The full kinetic edit replaces the earlier raw 62-second walkthrough. It includes animated captions, deliberate focus moves, music, an actual native window-layout sequence and the complete primary screen flow. README and site now include a dedicated window-manager explanation and demonstration image. Public release publishing is separate from pushing the prepared review branch.

The user requested the wallpaper for personal desktop use. Its source is installReleaseWallpaper(on:) in Tests/ZeraTests/ReleaseMediaRecorder.swift; the still exports render only those native vector layers at 5K. Export orientation must match the flipped capture canvas. The full-size wallpaper files are separate assets and are not fetched during normal page loading.

Final sharing delivery verification is retained in docs/media/v2/delivery-validation.json: 1,200 frames, 20 seconds at 60fps, H.264/yuv420p with AAC, faststart, six English caption cues and 38/38 visible-text contrast checks. Encoded camera/word-reveal proof sheets are in docs/media/v2/qc/. The film brand is Zera v2; bundle version is 2.0.0.
