# Zera animated — reusable files

Everything used to make the "Friday deploy" reel, kept so new Zera animations can start from here.
Zera is a coded 3D scene (Three.js) rendered frame by frame in headless Chromium, so the character
looks identical in every video.

## What is here

- `source/scene.js` — the 3D scene: Zera (fur, hair, hoodie, arms, eyes, mouth, sunglasses), the room,
  whiteboard, DEPLOY button, confetti, lights, camera and the whole animation timeline.
- `source/scene.html` — page that loads the scene, fonts and the caption overlay.
- `source/render.mjs` — renders stills or a full video (needs Node, Playwright + Chromium, ffmpeg).
- `source/sfx.py` — synthesises the sound effects (needs numpy).
- `source/part1.py` — removes the handle overlay from the podcast clip (needs opencv-python).
- `source/make_zera_voice.py` — generates a voice line with ElevenLabs. It reads the key from this
  repo's `.env` and saves `zera-vo.mp3` next to itself; change `TEXT`
  for a new line. Run it in Terminal on the Mac.
- `audio/` — the original ElevenLabs line, the pitched-up version used in the reel, and the sound effects.
- `timing/timeline.json` — when each beat happens (seconds from the start of Zera's scene).
- `timing/mouth-env.json` — mouth openness per frame (30 fps), measured from the voice.
- `reference/` — the finished reel and stills of Zera's main expressions.

## Re-render

    cd source
    npm install                      # three + fonts
    node render.mjs stills out 1.2 3.0 5.5                      # quick look at chosen moments
    TL="$(cat ../timing/timeline.json)" ENV=../timing/mouth-env.json SS=1.5 \
      node render.mjs video zera-scene.mp4 30                   # full scene, about 8 minutes

## Making a new animation

1. Write the new line, set `TEXT` in `make_zera_voice.py`, run it to get the voice.
2. In `scene.js`, change the whiteboard drawings (`drawBoard`), captions (`setCap` calls) and the
   beats inside `window.renderAt`. Zera's body, face and room can stay as they are.
3. Set the beat times in `timeline.json` to match the new voice, then render.

Voice in the reel: ElevenLabs stock voice "Sarah", pitched up 3 semitones (ffmpeg `rubberband=pitch=1.189`).
