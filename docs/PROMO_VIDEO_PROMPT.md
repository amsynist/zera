# Zera — 30-second launch video (Google Flow / Veo prompt)

Flow generates clips of about 8 seconds, so the video is four scenes stitched in Flow's
Scenebuilder. Upload two **ingredients** first and reference them in every scene:

- `zera-ref.png` — the approved Zera character (fluffy white puff, blue→violet tuft, black hoodie
  with purple Z). Use one of the clean standing poses from `Resources/Sprites` (e.g. `hello.png`
  or `card_greet.png`) on a plain background.
- `zera-screen.mp4` — your screen recording of the real app (the notch, the drop, the summary
  streaming in). Flow uses it for the UI look, colours and motion; the generated video should
  recreate it, not invent a different interface.

Paste the **Master style block** into every scene, then the scene text. 16:9, 24 fps,
4K if available. Keep the same seed for all four scenes if the model offers one.

---

## Master style block (prepend to every scene)

```
Style: polished 3D product film, soft studio lighting, shallow depth of field, macOS desktop
aesthetic. The character is "Zera" exactly as in the reference image: a fluffy round white
creature with a blue-to-violet swirl tuft, huge glossy black eyes with white highlights, pink
cheeks, oversized black hoodie with a purple "Z". Same proportions and plush render every shot;
never redesign her. The user interface is exactly as in the reference screen recording: dark
indigo translucent cards with rounded corners hanging under the MacBook notch, violet accent,
white text. Smooth camera moves, no cuts inside a scene, no text overlays unless specified,
no logos other than Zera's purple Z. Subtle ambient music, light UI tick sounds.
```

## Scene 1 — Entrance (0:00–0:08)

```
A MacBook Pro screen fills the frame, dark gradient wallpaper, menu bar at the top with the
notch. A thin brown rope drops down out of the notch and Zera slides down it with a tiny
bounce, swinging gently, then waves at the camera with a big open-mouth smile. A soft violet
ring pulses outward from her like a radar ping. A rounded speech bubble pops in beside her:
"Hi! I'm Zera 👋 your AI buddy". Camera: slow push-in from a wide desktop shot to a medium
shot on the notch. Mood: playful, warm.
```

## Scene 2 — Drop a file (0:08–0:16)

```
A cursor drags a red PDF file icon across the desktop toward Zera hanging at the notch. As it
gets close she switches to an excited arms-up pose and a dark indigo "Drop Files" card unfolds
smoothly beneath her; she leans over its top edge looking down at the file. The PDF lands in
a dashed drop zone that glows violet, five small file-type icons (PDF, Image, Code, Docs, Any
file) sit under it, and four action chips appear: "Summarize file", "Extract text",
"Explain file", "Ask Zera". Camera: follows the cursor, then settles centered on the card.
```

## Scene 3 — Claude works inside Zera (0:16–0:24)

```
The cursor clicks "Summarize file". The card morphs into a result panel: a red file tile,
"Analyzing Project-spec.pdf…", "Summarizing with Claude", a violet progress bar filling, and a
four-step checklist lighting up one by one: Reading file → Analyzing content → Generating
summary → Done. Beside the steps Zera sits at a tiny laptop typing, then switches to writing
with a purple pencil. Text streams into the panel line by line under a heading "Summary" with
bullet points; a blinking caret follows the last word. Camera: slow zoom into the panel, then a
gentle pull back as Zera jumps with confetti when "Done" lights up. No terminal window anywhere.
```

## Scene 4 — Everything else, and the sign-off (0:24–0:30)

```
Quick, smooth montage in one continuous camera drift across the desktop: a GitHub card with
PR rows slides under the notch and a toast appears — "New PR opened · Review Now / Later" —
with Zera pointing at it; then a Reminders card with a violet bubble "You have a meeting in
15 minutes!"; then an approval card "Claude wants to run a command" with Approve / Reject.
Zera waves goodbye from the notch. Final frame: clean dark background, Zera centered with her
purple Z, and crisp white text fading in: "Zera — your desktop buddy for Claude" and underneath,
smaller: "Open source · more coming". Hold 1.5 seconds.
```

---

### Tips for Flow

- Generate each scene 2–3 times and pick the take where her face and hoodie match the
  reference best; Veo is more consistent when the reference image is attached to every scene.
- If a scene drifts from the real UI, add "match the attached screen recording exactly" and
  drop the frame from your recording that shows that card as an extra ingredient.
- Use **Extend** on Scene 3 rather than a new clip if you want the summary text to stream for
  longer — it keeps the panel and Zera consistent.
- Export at the highest quality, then trim to 30 s in Flow's Scenebuilder; add the music there
  so all four scenes share one track.

---

## Voice-over

Two voices work together: a **narrator** (calm, friendly, slightly amused — think a good product
keynote, not an ad) and **Zera herself** (small, bright, upbeat; one short line per scene). About
20 narrated words fit in 8 seconds at a relaxed pace, so each scene below is 18–22 words.

### Script

| Scene | Narrator | Zera (in-scene) |
| --- | --- | --- |
| 1 · 0–8 s | *(1 s pause)* Meet Zera. She lives at your notch, says hi when you come by, and stays out of your way. | "Hi! I'm Zera — your AI buddy." |
| 2 · 8–16 s | Drop any file on her. PDFs, images, code, docs — she catches it and asks what you'd like done. | "Ooh — what's this?" |
| 3 · 16–24 s | Pick Summarize, and Claude reads it right here, through your own login. No terminal, no API key, no waiting. | "Done! Want me to explain it too?" |
| 4 · 24–30 s | Pull requests, meetings, Claude Code approvals — all a tap away. Zera is open source, and she's just getting started. | "See you at the notch! 👋" |

Word counts: 20 · 20 · 21 · 21.

### Voice direction

- **Narrator:** warm mid-range voice, 0.95× speed, light smile, no hard sells. Breathe at the
  em-dashes. Lower the pitch slightly on "No terminal, no API key" so it lands as a fact, not a
  boast.
- **Zera:** youthful, high-energy but soft, like a plush toy that is thrilled to see you. Keep
  her lines under 1.5 seconds and leave the narrator a beat of silence after each.
- Music under everything at −18 dB; duck it a further 6 dB while the narrator speaks.

### Three ways to get the audio

1. **Let Veo speak it (quickest).** Veo 3 generates dialogue from quoted lines. Add to the end
   of each scene prompt: `Zera says in a bright, youthful voice: "Hi! I'm Zera — your AI buddy."`
   and `A warm narrator voice says: "Meet Zera. She lives at your notch…"`. Expect the narrator
   to vary between scenes — fine for a first cut, not for the final.
2. **Generate once, lay over (recommended).** Record the narrator lines as one file in a TTS
   tool (ElevenLabs, Google Cloud Text-to-Speech "Studio" voices, or Apple's `say -v Ava`), and
   Zera's four lines in a second, higher voice. Then in Flow's Scenebuilder (or CapCut / iMovie)
   drop the narration on one track and Zera's lines on another, aligned to the scene starts at
   0, 8, 16 and 24 seconds. Generate the video scenes with `no dialogue, ambient sound only` so
   nothing clashes.
3. **Record yourself.** Same alignment; a phone in a quiet room is enough for a launch video.
   Normalise to −16 LUFS.

Quick local draft to time the cut before you pay for voices:

```bash
say -v Ava -r 165 -o narrator.aiff "Meet Zera. She lives at your notch, says hi when you come by, and stays out of your way. [[slnc 1200]] Drop any file on her. PDFs, images, code, docs — she catches it and asks what you'd like done. [[slnc 1200]] Pick Summarize, and Claude reads it right here, through your own login. No terminal, no API key, no waiting. [[slnc 1200]] Pull requests, meetings, Claude Code approvals — all a tap away. Zera is open source, and she's just getting started."
```

---

## Merging the four clips and adding the voice

Flow's Scenebuilder has no prompt box for editing — you place the clips by hand (Scenebuilder →
add Scene 1…4 in order → trim each to 8 s / 6 s → Export). The voice is added either by an
AI editor that accepts clips plus instructions, or by a TTS tool plus a normal editor. Prompts
for each are below.

### A. One prompt for an AI video editor (Google Vids, Descript, CapCut "AI edit", Runway)

Upload `scene1.mp4 … scene4.mp4`, the Zera reference image and your logo-less brand colour,
then paste:

```
Assemble a 30-second launch video from the four attached clips, in order: scene1 (0:00–0:08),
scene2 (0:08–0:16), scene3 (0:16–0:24), scene4 (0:24–0:30). Trim scene4 to 6 seconds, ending
on the final title frame. Join the clips with 8-frame cross-dissolves; no other transitions,
no stock footage, no extra text except what is already in the clips.

Add a narrator voice-over, warm mid-range, friendly, slightly amused, speaking at 0.95× speed,
starting 1 second into each scene:
0:01 "Meet Zera. She lives at your notch, says hi when you come by, and stays out of your way."
0:09 "Drop any file on her. PDFs, images, code, docs — she catches it and asks what you'd like done."
0:17 "Pick Summarize, and Claude reads it right here, through your own login. No terminal, no API key, no waiting."
0:25 "Pull requests, meetings, Claude Code approvals — all a tap away. Zera is open source, and she's just getting started."

Add a second, character voice for Zera — small, bright, youthful, like a happy plush toy —
placed right after each narrator line finishes:
scene1 "Hi! I'm Zera — your AI buddy."
scene2 "Ooh — what's this?"
scene3 "Done! Want me to explain it too?"
scene4 "See you at the notch!"

Music: light, upbeat electronic-acoustic bed, no vocals, at −18 dB, ducked a further 6 dB while
anyone speaks, fading out over the last second. Keep the clips' own ambient UI sounds at −24 dB.
Loudness −16 LUFS. Export 1920×1080, 24 fps, H.264, stereo AAC. Also export a 1080×1920 vertical
cut that reframes on Zera and the active card.
```

### B. If you'd rather make the voices separately (ElevenLabs / Google TTS / Apple `say`)

Narrator — one file. Paste into the TTS tool exactly (the `<break>` tags are the 8-second
scene boundaries; swap them for `[[slnc 1000]]` in Apple `say`):

```
Meet Zera. She lives at your notch, says hi when you come by, and stays out of your way.
<break time="2.0s"/>
Drop any file on her. PDFs, images, code, docs — she catches it and asks what you'd like done.
<break time="2.0s"/>
Pick Summarize, and Claude reads it right here, through your own login. No terminal, no API key, no waiting.
<break time="2.0s"/>
Pull requests, meetings, Claude Code approvals — all a tap away. Zera is open source, and she's just getting started.
```

Voice settings that work well for the narrator: ElevenLabs "Rachel" or "Adam", Stability 55,
Similarity 75, Style 20, speed 0.95. For Zera use a young, bright voice ("Lily" or a cloned
child-like voice), Stability 40, Style 55, speed 1.05, and generate the four lines as four
separate files so you can nudge each one.

Then in Flow's Scenebuilder, CapCut or iMovie: narration on track 1 starting at 0:01, Zera's
four files on track 2 at ~0:06, 0:14, 0:22, 0:28, music on track 3. Export as in A.

### C. If you want Veo itself to voice a clip

Regenerate (or Extend) that scene with the same prompt plus:

```
Audio: a warm, friendly narrator voice says "<that scene's narrator line>". Afterwards Zera
says in a small, bright, youthful voice "<that scene's Zera line>". Light upbeat music bed,
soft UI tick sounds, no other speech.
```

Do this for all four or none — mixing Veo's narrator with a TTS narrator will sound like two
people.
