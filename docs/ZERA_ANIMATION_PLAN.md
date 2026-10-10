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

- [x] Shared glossy eyes, happy squints, eyelids, brows and animated mouth layers.
- [x] Hover acknowledgement and a four-tap huff with shaking, squash and recovery.
- [x] Keep the current pose during a poke reaction instead of replacing it with a static expression.
- [x] Cross-fade pose changes; draw the rope and straw in front of facial layers.
- [ ] User review of repeated taps and expression timing.

## Phase 3 — All screens except the app opener

- [x] Share one 30 fps animation clock with weak view membership; pause hidden or occluded views.
- [x] Interactive body motion, pointer response, breathing, hover and taps for screen mascots and companions.
- [x] Prepare facial rigs for `hang_wave`, `hang_climb`, `hang_peek`, `hang_smile`, `hang_swing` and `boba`.
- [x] Preserve existing screen layout, shared typography and control spacing.
- [x] Check detached-view release and all eight screen layouts.
- [ ] Independent facial layers for `hang_think` and `hang_upsidedown`. Image generation rejected these edits; their original artwork still has animated body motion and taps.
- [ ] Independent facial layers for the remaining decorative standing poses. Body animation and interaction are active now.
- [ ] User review on Home, Claude, Shelf, Clipboard, Tasks, PRs, Reminders and Settings.

The app opener is excluded from this change, as requested.

## Phase 4 — Cursor-side water visit

- [x] Route hydration alerts to a persistent nonactivating visit rather than an expiring banner.
- [x] Jump from the perch to the cursor's display on a smooth arc; mirror the layout near the right edge.
- [x] Keep the live boba rig throughout the visit; lean and tap with a ripple, blink, follow the cursor and animate speaking.
- [x] Rotate six playful prompts and distinct facial/body reactions every 12 seconds until **Took a sip!** is clicked.
- [x] Mark waiting hydration occurrences done once, thank the user, and return to the perch.
- [x] Coalesce reminders during a visit; preserve a new reminder arriving after acknowledgement.
- [x] Use existing palette, typography, rounded button, backdrop blur and subtle surface gradient.
- [x] Respect Reduce Motion; no synthesized clicks or keyboard events, no new global monitor.
- [x] Verify persistence, acknowledgement, flight endpoints and display-edge placement.
- [x] Inspect waiting/thank-you renders and a seven-second local motion preview.
- [ ] User review of the water visit in everyday use, including multiple displays.

### Water animation refinement — 10 October

- [x] Crouch before takeoff; arc with a gentle tilt and stretch; squash, rebound and settle at the exact landing point.
- [x] Keep one character pose through travel and waiting, avoiding pose-swap flashes.
- [x] Add hopeful puppy eyes, skeptical eyelids and a smirk, a dramatic droop, a boba cheer and a thoughtful look while waiting.
- [x] Brief acting at the start of each line, with quiet idle between lines; thank the user with a small happy bounce.
- [x] Check arrival and return endpoints, repeated acknowledgement, waiting persistence and all six expressions.
- [x] Inspect local flight and patience previews; 17 selected checks and release bundle build passed.
- [ ] User review of the refined jump and waiting reactions in the running app.

New local preview: `.build/ui-review/zera-water-patience.gif` compresses the six 12-second waiting beats for review. Production timing remains 12 seconds per line. The temporary one-minute test reminder remains active in local app data.

### Water replies and clipping fix — 10 October

- [x] Keep the original character and card sizes; add transparent animation space for the tilt, bounce and squash after landing.
- [x] Check the actual drawing's transparent outer edges across the jump, all six waiting beats and repeated taps.
- [x] Replace the formal acknowledgement with **Took a sip!**, a droplet and a quiet shared gradient button; hover makes Zera smile.
- [x] Add **One sec…** for 20 seconds of quiet company without completing the reminder.
- [x] Cheer with “Sip, sip, hooray!”, then return once; retain reminder coalescing.
- [x] Remove redundant window repositioning while Zera waits.
- [x] Native animation/render suite passed (19 checks), followed by 10 water checks including pixel-edge coverage; release bundle build passed.
- [ ] User review of the clipping fix and new replies during the one-minute test reminder.

## Phase 5 — Website companion

- [x] Hang Zera from the top-center notch, with a smaller perch while scrolling.
- [x] Reuse the app's blank-face artwork and facial anchors; draw live glossy eyes and mouth as SVG layers.
- [x] Smooth bounded cursor following, breathing, blinking, hover response and tap bounce.
- [x] Four quick taps trigger a huff, then settle back; support touch and keyboard activation.
- [x] Refine the hero, shared typography, quiet gradient buttons and glass surfaces.
- [x] Slow the screen tour; add pause/play, arrow-key navigation and accessible tab selection.
- [x] Pause the mascot clock in hidden tabs; stop idle motion for Reduce Motion.
- [x] Check desktop and narrow mobile layouts, asset paths, script syntax and interaction lifecycle.
- [x] Add an interactive water-break preview: bounded hop, live face, six waiting lines, both replies, cheer, return and replay.
- [x] Pause the preview timer and CSS animation offscreen or in a hidden tab; respect Reduce Motion.
- [x] Check water reply timing, visibility pause/resume and replay; inspect 1440px desktop and 390px mobile layouts and keyboard confirmation. No horizontal overflow on mobile and no browser errors.
- [x] Document Hydration setup, cursor-side visits and reply behavior in the README.
- [ ] User review of the local website preview.
- [ ] Public deployment after merging the website changes to `main` (the Pages workflow deploys from `main`).

Website review: `python3 -m http.server 8768 --bind 127.0.0.1 --directory site`.
Website checks: `node scripts/check-site.mjs`.

## Local review

```sh
env CFFIXED_USER_HOME="$PWD/.build/ui-review-home" \
  ZERA_RENDER_SCREENS="$PWD/.build/ui-review" \
  ZERA_RENDER_FACE=1 ZERA_RENDER_WATER=1 \
  swift test --filter 'ZeraFaceTests|PokeReactionTests|WaterVisitTests|ScreenRenderTests/testRenderMascotPoses|ScreenRenderTests/testRenderWaterVisitMotion|ScreenRenderTests/testRenderWaterWaitingExpressions'
```

Outputs include `zera-all-poses.png`, `zera-water-waiting.png`, `zera-water-thanks.png` and `zera-water-visit.gif` under `.build/ui-review`. Captures stay local; they are not published to CI or PRs. The original phase-one preview remains available with `ScreenRenderTests/testRenderZeraFace`.

Verification: 38 selected animation, recurrence and screen-layout tests passed; release build passed. Two local preview tests also passed and were visually reviewed. The standalone icon renderer also passed.

## Asset provenance

Asset: `Resources/Sprites/hang_smile_base.png`.
Source: Zera's existing `Resources/Sprites/hang_smile.png`.
Prepared with the built-in image generation tool, preserving transparency. Original sprite retained.

Final edit prompt:

> Use case: precise-object-edit. Edit target: attached hanging Zera PNG. Produce an animation body base on transparent background. REMOVE ONLY the two glossy black eyes and their white glints, the tiny mouth and the eyebrow marks; reconstruct the pale cream/pink softly shaded face underneath seamlessly. KEEP every other detail unchanged: exact angled head shape, blue purple tuft, pink cheeks, fuzzy rim, hand positions, body, black hoodie, purple Z, feet, brown rope, original pose and silhouette. Keep the rope straight vertical and identical rope position; same image proportions, composition, framing and bounding box, no extra margins or zoom. This is the same character and same sprite, just a blank face for layered animated eyes/mouth. No new facial features, no expression, no text, no redraw of the clothing, no opaque background.


Additional blank-face bases: `hang_wave_base.png`, `hang_climb_base.png`, `hang_peek_base.png`, `hang_swing_base.png`, `boba_base.png`. Each was edited from its same-named original using the built-in image tool; original sprites are retained. Large bases decode to at most 528 pixels at runtime.

Header base prompt (replace NAME with the sprite name):

> Use case: precise-object-edit. Edit target: NAME, attached existing Zera sprite. Produce the SAME sprite as an animation body base with a blank face. Remove ONLY the two eyes including white glints or closed-eye arcs, eyebrows, and mouth. Seamlessly reconstruct the cream/pink face shading underneath. Preserve every other detail exactly: head silhouette, pose, tilt, scale, placement, purple-blue tuft, blush, hands, black hoodie and purple Z, feet, rope, stars or question marks. Keep original framing, proportions, silhouette and rope occlusion. Transparent alpha background. No new facial features, extra margins, zoom, text, or pose changes.

Water base prompt:

> Prepare the attached friendly Zera character holding a boba cup for a layered facial animation. Make a clean blank face layer: replace the eye, eyebrow and mouth details with matching soft cream and pink skin shading. Keep the character, expression silhouette, tuft, cheeks, clothing, cup, straw, proportions, pose and transparent background exactly like the original. The drink and straw stay intact. No additional margins, text or pose changes.

Website asset `site/assets/zera-hang-base.png` is a 528-pixel PNG derivative of the existing `hang_smile_base` artwork (168 KB); it uses the same provenance above. Website animation uses native SVG and browser APIs, with no new dependency.

Website asset `site/assets/zera-boba-base.png` is a 528-pixel derivative of the existing `boba_base.png` artwork (301 KB), with the same provenance above. Water preview captures remain under `.build/ui-review/`.
