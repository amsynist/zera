# Sharing-film implementation brief

This is a 20-second, 60fps native sharing demonstration with five prominent caption beats. The actual Android app stays left and the actual Mac stays right. Device cases are presentation framing; no app UI is recreated. The exact same photo is carried by the Android gesture, native Mac arrival and received original in Preview.

## Motion and readability

One paused, seek-safe GSAP timeline owns the film. Masked words enter through transform-only movement, then hold as complete readable phrases. Caption text is 96–100 px at 1080p. Camera poses use one wrapper with continuous x/y/scale interpolation. Their movement stays above native recorded motion and does not retime the source.

No animated layout, live blur, per-frame audio callback or rebuilt gradient is used. A sparse precomputed music envelope modulates one static localized light through opacity tweens. The actual Mac ripple stays visible below the caption area. The ending camera pose fits both complete devices in frame.

## Sources

Verified take3 is installed under composition/assets/native. Raw recordings and timing metadata are retained in its source directory. Matching working clips preserve the global 1853.6–1865.4 interval within epoch prefix 179376. Android start alignment uses the supplied recording-start estimate and sampled clock offset. source-cadence.json independently counts real recorded frames in the gesture-to-Preview window. source-provenance.json records the exact original and received-byte verification.

Only the physical gap between devices contains a brief bridge of the exact original image. It never paints over native screen UI. The final actual Preview window remains visible across the source clip-to-still hold.

## Validation and delivery

The strict Hyperframes gate covers runtime, layout, motion, contrast, craft and audio. Native footage and all caption/camera transitions are inspected from encoded frames. keyframes-proof.json and qc/caption-motion-proof.jpg document actual word motion. Matching sidecars are captions.srt, captions.vtt and caption-timeline.json.

The final web MP4 uses H.264, yuv420p, AAC and faststart. It contains 1,200 video frames and 20 seconds of audio. A settled, fully framed closing sharing frame supplies brag.jpg and frame zero of the video. No publishing, telemetry/feedback submission, cloud render, voice generation or native-source change is part of this workflow.
