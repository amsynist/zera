# Zera "on the cards" poses — generation prompt

The cards (Home, Drop Files, GitHub, Reminders, the processing panel, toasts) show Zera
standing *inside* the panel with a speech bubble. The app already uses the standing poses from
the main sheet for this; the sheet below adds the twelve poses the mock-ups call for (leaning
over an edge, catching a file, sitting at a laptop seen from the side, …) at matching quality.

Paste the block into your image generator together with the approved Zera reference image.
Generate at the largest size available (4096 px wide is ideal). Drop the result into
`Resources/` as `card-sheet.png`; the slicer cuts it into `Resources/Sprites/card_*.png` using
the names listed, in grid order, and the app picks them up on the next build.

---

```
Create a sprite sheet of the character in the attached reference image — "Zera", a fluffy
white round creature with a blue-to-violet swirl tuft on top, huge glossy black eyes with big
white highlights, soft pink cheeks, a tiny mouth, wearing an oversized black hoodie with a
purple "Z" on the chest and small white paws and feet. Same character, same proportions, same
3D plush render style, same soft lighting and colours as the reference. Do not redesign her.

OUTPUT FORMAT
- One PNG, 4096 × 1365 px (or the largest 3:1 size available), fully TRANSPARENT background
  (true alpha — not white, not a checkerboard, no backdrop, no floor, no vignette).
- No ground shadows, no text, no labels, no borders, no watermark. Clean anti-aliased edges,
  no outline strokes.

GRID
- A strict grid of 6 columns × 2 rows = 12 cells, each cell 682 × 682 px.
- Exactly one pose per cell, centred, with at least 60 px of empty transparent margin on every
  side. Nothing may touch or cross a cell border — props, sparkles, confetti and ledges included.
- Same scale in every cell: her body about 400 px tall. Same camera: slightly above eye level,
  three-quarter front view, so she looks natural sitting at the edge of a panel.

ROW 1 — GREETING & FILES
1. sitting on the ground, paws pressed together in front of her chest, warm closed-eye smile,
   head tilted a little (the "Good morning!" pose)
2. leaning over a thin flat horizontal ledge from above, only her head, shoulders and both paws
   on the ledge, looking straight down at the viewer with a curious smile (the ledge is a short
   plain light-grey bar fully inside the cell)
3. standing with both paws stretched out in front, catching a red "PDF" document that is
   falling toward her, excited open-mouth smile, two small motion lines above the document
4. holding a white document with grey text lines up in one paw, reading it with eyebrows raised,
   small purple "?" beside her head
5. sitting sideways (profile, facing the viewer's right) at an open silver laptop, paws on the
   keyboard, eyes on the screen, calm focused expression — laptop fully inside the cell
6. standing, writing on a white sheet with an oversized purple pencil, tongue slightly out in
   concentration

ROW 2 — ALERTS & REACTIONS
7. standing, pointing to the viewer's right with one paw, encouraging smile, two small yellow
   sparkles beside her pointing paw
8. standing, holding a small golden bell up in one paw, the other paw cupped beside her mouth,
   open-mouth "calling out" expression, three short sound lines by the bell
9. jumping with both paws up, eyes closed in a big smile, small colourful confetti pieces and
   two yellow sparkles around her (all inside the cell)
10. standing with a small bright red notification dot (a plain red circle) floating at the top
    right of her head, eyes wide, one eyebrow raised, curious expression
11. sitting with slumped shoulders, eyes half closed, one paw rubbing an eye, three purple "z"
    letters rising beside her
12. standing, thumbs up with one paw, winking, a small green check mark floating beside her
```

Slice names, in grid order: `card_greet`, `card_peek_down`, `card_catch_pdf`, `card_read_q`,
`card_laptop_side`, `card_writing`, `card_point_sparkle`, `card_bell`, `card_cheer`,
`card_notify`, `card_sleepy_sit`, `card_thumbs_wink`.
