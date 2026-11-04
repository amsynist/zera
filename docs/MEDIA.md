# Zera 2 media

The v2 site and README use fresh native screenshots and recordings. Published media lives in site/assets/v2/. The 24-second sharing film is made with the explicitly invoked brag/Hyperframes workflow; the longer walkthrough records every current primary screen. Demo tasks, files and artwork are fictional. Device framing is motion design; app surfaces are actual native captures. No voiceover is used.

## Reproduce the native walkthrough

```sh
mkdir -p .build/v2-media-home .build/v2-media
env CFFIXED_USER_HOME="$PWD/.build/v2-media-home" \
  ZERA_RENDER_SCREENS="$PWD/.build/v2-media" ZERA_V2_MEDIA=1 \
  swift test --filter ScreenRenderTests/testRecordV2Release
```

The fixture emits 24fps-targeted JPEG frames, measured timestamps, scene/crop metadata and cropped native PNGs. Encode using the timestamp deltas, not an assumed fixed capture cadence. The current complete take is about 62 seconds. Native capture runs in a disposable home and never uses real clipboard/account/calendar content. Normal `swift test` skips these recordings.

## Phone-to-Mac hero

The test-only Android instrumentation’s `-e media seed` mode creates synthetic gallery artwork. `-e media share` opens the real gallery photo and injects a real right-edge gesture. Mobile data was disabled on the disposable emulator. A local isolated Zera receiver listens on port 18989 and saves in a temporary inbox. `ScreenRenderTests/testRecordV2PhotoReceiver` captures only its clean fixture windows and the exact newly opened “Zera coast” Preview window. The received PNG was independently SHA-256 matched with the phone original (28,379 bytes). This is functional evidence, not a physical Samsung or router-throughput claim.

Raw phone/Mac starts and approach/release/save markers are recorded in the ignored media workspace. The film selects an unchanged eight-second synchronized segment; no source speed-up is used. An exact-original image bridges only the physical gap between the device frames. It never replaces native UI. The ordinary-document notch/Shelf sequence is from the separately recorded native walkthrough.

## Publication files

- sharing.mp4 / sharing-poster.jpg — main sharing-first film, poster also baked into frame zero.
- walkthrough.mp4 / walkthrough-poster.jpg — complete native screen flow.
- screens/*.webp — current app screens, cropped at their native island boundaries.
- media-provenance.json — source timing, fixture and verification summary, without private paths.

The build/composition workspace is ignored. Public storyboard, brief and share copy are retained under docs/media/v2/ for the release. Keep videos local until the requested publishing step.

Music: “Happy Beats / Business Moves Vol. 12” by Sascha Ende, ende.app, CC BY 4.0. Sparse UI accents are CC0 from the brag bundled library where used. These are not covered by the repository’s MIT code license. Zera’s original art remains under LICENSE-ASSETS.md.
