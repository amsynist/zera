# Zera animation

Branch: `animating-zera`. Keep Zera's own design and native AppKit renderer.
Reference studied: [Coucou's animation engine](https://github.com/Louis-CFM/coucou/blob/main/NotchBuddy/Sources/CoucouKit/BotEngine.swift) and [cursor mapping](https://github.com/Louis-CFM/coucou/blob/main/NotchBuddy/Sources/App/BotCanvasView.swift). No Coucou character artwork or source code was copied.

## Phase 1 — Hanging idle pose

- [x] Prepare a blank-face body base for `hang_smile`; preserve the original sprite as fallback.
- [x] Draw glossy eyes, highlights, eyebrows and mouth independently in sprite coordinates.
- [x] Follow the cursor with bounded gaze and elapsed-time smoothing; reuse the existing cursor polling and animation clock.
- [x] Blink at irregular 3–6 second intervals, with a quick close and slower reopen.
- [x] Attach the face to the existing breathing and pendulum transform so it cannot drift off the body.
- [x] Respect Reduce Motion: immediate gaze changes and no animated blink.
- [x] Use the existing window-visibility clock lifecycle; add no timers or global event monitors.
- [x] Decode the body base at a maximum 528 pixels, then use the existing small rendered-sprite cache.
- [x] Fix the initial pose fade so the first paint is visible immediately.
- [x] Check blink timing, gaze at different frame rates, and existing poke reactions.
- [x] Inspect local left/right stills and a six-second motion preview.
- [ ] User review of cursor response and blinking in the running app.

## Phase 2 — Expressions and reactions

- [ ] Happy squint, surprised eyes, sleepy eyelids and worried eyebrows.
- [ ] Hover acknowledgement and tap/repeated-poke facial reactions.
- [ ] Expression priorities and clean return to idle after interruptions.

## Phase 3 — Activity and other poses

- [ ] Rig standing idle, peeking and climbing poses with their own facial anchors.
- [ ] Connect facial expressions to thinking, approval, completion and error states.
- [ ] Reuse the rig in the opener and screen mascots as each pose is prepared.
- [ ] Review transitions, small sizes, display changes and reduced motion across those surfaces.

## Local review

The first rig is active only for the hanging `hang_smile` pose. Other poses still use their existing sprites. Idle fidgets and mood changes may temporarily switch away from the rig.

Run the on-demand preview locally:

```sh
env CFFIXED_USER_HOME="$PWD/.build/ui-review-home" \
  ZERA_RENDER_SCREENS="$PWD/.build/ui-review" ZERA_RENDER_FACE=1 \
  swift test --filter 'ZeraFaceTests|PokeReactionTests|ScreenRenderTests/testRenderZeraFace'
```

This writes `zera-face-idle.png`, `zera-face-left.png`, `zera-face-right.png` and `zera-face-motion.gif` under `.build/ui-review`. Captures are local diagnostics, not CI artifacts.

## Asset provenance

Asset: `Resources/Sprites/hang_smile_base.png`.
Source: Zera's existing `Resources/Sprites/hang_smile.png`.
Prepared with the built-in image generation tool, preserving transparency. Original sprite retained.

Final edit prompt:

> Use case: precise-object-edit. Edit target: attached hanging Zera PNG. Produce an animation body base on transparent background. REMOVE ONLY the two glossy black eyes and their white glints, the tiny mouth and the eyebrow marks; reconstruct the pale cream/pink softly shaded face underneath seamlessly. KEEP every other detail unchanged: exact angled head shape, blue purple tuft, pink cheeks, fuzzy rim, hand positions, body, black hoodie, purple Z, feet, brown rope, original pose and silhouette. Keep the rope straight vertical and identical rope position; same image proportions, composition, framing and bounding box, no extra margins or zoom. This is the same character and same sprite, just a blank face for layered animated eyes/mouth. No new facial features, no expression, no text, no redraw of the clothing, no opaque background.
