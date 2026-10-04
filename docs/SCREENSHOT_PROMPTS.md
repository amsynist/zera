# README images — generation prompts (clean versions)

Prompts to recreate the six README images **without** the problems the old ones had:
no personal identifiers, no real people, no company logos (Apple, GitHub, Anthropic/Claude, React,
VS Code, Notion, Slack…), no unbranded-looking-but-real products, and only features Zera really has.

How to use (ChatGPT / any image model):
1. Attach the Zera character reference (a clean standing pose, e.g. `Resources/Sprites/hello.png`).
2. Paste the **Rules block** first, then the prompt for the image you want.
3. Before committing, check the result with the **Checklist** at the bottom. Regenerate anything that fails.
4. In the README, caption AI images as *"Illustration"* — real screenshots of the app are always better.

---

## Rules block (paste before every prompt)

```
STRICT RULES — follow exactly:
- No real company logos or brand marks anywhere: no Apple logo, no GitHub Octocat/Invertocat, no
  Anthropic or Claude starburst/asterisk logo, no React, VS Code, Next.js, Vercel, Tailwind, Radix,
  Notion, Slack, Google, Microsoft or any other logo. Use simple generic glyphs instead (a ">_"
  terminal, a branching pull-request glyph, a folder, a bell, a calendar, a water drop, sparkles).
- No real people, no photographic or realistic faces. Avatars are plain coloured circles with
  two-letter initials.
- Laptops, phones, mugs, headphones are plain and unbranded: no logo on the laptop lid, no
  recognisable product design.
- All names are fictional: organisation "demo-org", users "alex-dev", "sam-codes", "jordan-ui",
  "riley-ops", "casey-qa". The signed-in user is "@demo-user". Paths look like "~/Projects/zera".
- Menu bar: plain dark bar, NO logo at the left edge, only the word "Zera".
- Only the UI elements described below. Do not invent extra tabs, integrations or buttons.
- Style: dark indigo translucent glass cards with rounded corners (about 22 px), hairline borders,
  violet-to-purple gradient accents (#7C5CFF → #9B5BFF), white and lavender text, soft glow.
- The character is "Zera" exactly as in the attached reference: fluffy round white creature,
  blue-to-violet swirl tuft, big glossy black eyes, pink cheeks, black hoodie with a purple "Z".
  Do not redesign her.
- Crisp, legible UI text, no lorem ipsum, no watermark.
```

---

## 1. `docs/banner.png` — hero banner (2000 × 780)

```
Wide hero banner, 2000×780, dark indigo night-desk background with soft violet bokeh.
LEFT: large gradient wordmark "Zera" (violet→cyan), with a small sparkle. Under it:
"Your AI desktop buddy" and a smaller line "Open-source macOS app · works with Claude Code and
GitHub". Below, a row of five rounded square feature tiles with generic glyphs and captions:
  ">_" terminal glyph — "Claude Code sessions"
  branching pull-request glyph — "Pull request alerts"
  folder with arrow glyph — "File Shelf"
  bell glyph — "Reminders & Calendar"
  2×2 grid glyph — "Notch companion"
RIGHT: Zera peeking over the top edge of an unbranded laptop screen (no logo), a second Zera
hanging from a rope above, a small sleepy Zera with "z z" at the side. On the right edge three
glass notification cards: (pull-request glyph) "New PR · want me to take a look? 👀",
(folder glyph) "Drop files here · I'll help you work with them", (">_" glyph) "Claude Code needs
your approval · run this command?".
```

## 2. `docs/screen-overview.png` — app overview collage (1536 × 1024)

```
1536×1024 collage of Zera's real screens floating on a dark desktop. Plain menu bar at the top
with only "Zera" at the left and a clock "Mon 10:24 AM" at the right (no logo). Zera hangs from
the notch with a bubble "Hi! I'm Zera 👋".
Cards to show (only these):
1. HOME: "Good morning! 👋 What shall we do today?", a search field "Search files, notes, PRs, or
   ask Zera…", a "Needs attention" list (bell glyph "Drink water is due", pull-request glyph
   "2 PRs need your review"), "Recent" (PDF tile "Project-spec.pdf · Summarized · 2 min ago"),
   and Quick Actions tiles: Summarize File, Explain, Extract Text, New Note, Screenshot, Start Timer.
2. DROP FILES: dashed drop zone "Drop files here", five file-type tiles (PDF, Image, Code, Docs,
   Any file) and four action tiles: Summarize, Explain, Extract Text, Ask Zera. Zera holding a
   red generic "PDF" page.
3. FILE RESULT: "Project-spec.pdf" with tabs Summary · Key Points · Full Text · Q&A; a short
   summary paragraph about "a sample project specification" and three bullet points; buttons
   Copy and Ask follow-up.
4. CLAUDE CODE APPROVAL: header with ">_" glyph "Claude Code wants to run a command", a code box
   "npm test", working directory "~/Projects/zera", buttons Reject and Approve (violet).
5. REMINDERS & CALENDAR: tabs "Today 4 · Upcoming 12 · Completed 3", a timeline of four rows:
   "9:30 AM Standup" (calendar glyph, chip "in 25 min"), "11:00 AM Drink water" (blue drop tile,
   chip "Due now"), "2:00 PM Design review" (sparkles tile), "6:00 PM Gym" (bell tile).
Keep every card readable; no other apps, no logos.
```

## 3. `docs/screen-claude-sessions.png` — Claude Sessions (1536 × 1024)

```
1536×1024, two glass panels side by side.
LEFT PANEL "Claude Sessions": a rounded tile with a ">_" terminal glyph in a coral gradient (NOT
the Claude logo), title "Claude Sessions", subtitle "Manage and monitor your Claude Code sessions",
violet button "+ New Session" with Zera peeking over it and a bubble "2 sessions running — let's
check them! 👀". Segmented filter "All 5 · Running 2 · Waiting 1 · Completed 2" and a search box
"Search sessions…". Session rows (each: ">_" tile, title, path · branch, status chip, elapsed,
thin progress bar, square stop button, "…" button):
  "Implement file parser" — ~/Projects/zera · feature/file-parser — Running 3m 24s — 62%
  "Fix layout issues" — ~/Projects/zera · ui/fixes — Running 12m 8s — bar without a percentage
  "Review test failures" — ~/Projects/notes-app · main — Waiting (amber) — "Waiting for your approval…"
  "Refactor data pipeline" — ~/Projects/notes-app · refactor/pipeline — Completed 2h ago
Bottom tip card with Zera at an unbranded laptop: "Zera's tip ✨ I'll let you know if anything
needs your attention!"
RIGHT PANEL (selected session): ">_" tile, title "Implement file parser", green chip "Running",
"3m 24s", path "~/Projects/zera · feature/file-parser", buttons "Stop" (red outline) and "…".
Tabs: Live · Files 12 · Changes 5 · Tools 3 · Timeline. Progress card "60% · Analyzing files and
updating code… · 3m 24s elapsed · ETA ~1m 30s". Zera with bubble "Claude is working on it… Reading
files, making changes." Dark console log with check marks: "Reading project structure ✓",
"Found 42 relevant files", "Updating FileParser.swift ✓", "Running tests… 12.4s". Detail rows:
Current task "Implement a more robust file parser", Working directory "~/Projects/zera", Model
"Claude Sonnet". Input "Ask Claude about this session…" and four buttons: Summarize progress,
Explain changes, Find issues, Open in editor.
```

## 4. `docs/screen-github.png` — Pull requests (1084 × 1450)

```
1084×1450, one tall glass card.
Header: rounded tile with a white branching pull-request glyph on a violet gradient (NOT the
GitHub logo), title "GitHub PRs", subtitle "@demo-user · checked 1 min ago". Zera at an
unbranded laptop with a bubble "10 open PRs — want a look? 👀", a refresh button and a "…" button.
Segmented tabs: "Open 10 · Review 4 · CI 10 · Approvals 3". Search "Search PRs, repositories, or
authors…" and filter buttons Author ⌄ · Label ⌄ · Repo ⌄ · Sort ⌄.
Five PR rows (each: plain geometric repo tile in a different colour — circle, triangle, square,
hexagon, diamond — repo name, "#number", title, author with an initials avatar, time, CI chip,
three small initials avatars for reviewers, comment count, violet "Review" button, "…" button):
  demo-org/notes-app #128 — "Add offline sync for notes" — alex-dev · 2 hours ago — CI passing — 12
  demo-org/api-server #342 — "Improve request validation" — sam-codes · 5 hours ago — CI failed — 8
  demo-org/design-system #57 — "New button sizes and focus ring" — jordan-ui · 1 day ago — CI passing — 15
  demo-org/mobile #219 — "Fix crash on empty profile" — riley-ops · 1 day ago — Needs review (amber) — 6
  demo-org/docs #41 — "Getting started guide" — casey-qa · 2 days ago — CI passing — 4
Bottom insight card: Zera hugging a plain violet pull-request glyph tile (not a logo), text
"2 PRs have failing checks 😬 — want me to summarize the issues or check the logs?" and a violet
split button "Open in Browser ⌄".
```

## 5. `docs/screens.png` — feature sheet (1536 × 1024)

```
1536×1024 numbered feature sheet on a dark desktop with a plain menu bar (no logo, "Zera" only).
Top row: Zera states — "Idle (in notch)" → "Hover" → "Click", and small poses labelled
"New notification", "Thinking", "Working" (at an unbranded laptop), "Success", "Sleepy".
Numbered cards (only these):
1. Home Dashboard — greeting, search, Recent list, Quick Actions.
2. GitHub PRs — tabs "Open (3) · Review (2) · CI · Approvals", rows with a pull-request glyph and
   fictional titles ("Add offline sync", "Improve validation", "Fix crash on empty profile").
3. Settings / Integrations — rows: "Claude Code" (">_" glyph, toggle on), "GitHub" (pull-request
   glyph, toggle on), "Calendar" (calendar glyph, toggle on), "Shelf" (folder glyph, toggle on).
   No other integrations, no third-party logos.
4. Drop Files — drop zone and five file-type tiles.
5. File Processing — "Analyzing file… Summarizing with Claude", progress bar, four steps.
6. Quick Actions — Open Claude, Search Files, Create Note, Start Timer, Screenshot.
7. Reminders & Calendar — tabs Today / Upcoming / Completed, rows "Team sync", "Drink water",
   "Review PRs", "Gym", and a small notification "Drink water 💧 · Snooze · Mark as done".
8. Notification toast — pull-request glyph, "New PR opened · #125 · feat/notifications", buttons
   "Review Now" and "Later".
```

## 6. `docs/sprite-sheet.png` — character sheet (1374 × 1145)

```
Character sprite sheet of Zera on a fully transparent background, 6 columns × 5 rows, one pose per
cell, same scale and lighting, clean edges, no text, no labels.
Row 1: hanging from a brown rope — idle, waving, curious "?", sleepy "z", upside-down, excited.
Row 2: standing — idle, hello wave, giggle with a heart, surprised "!!", cheering with sparkles,
dancing with confetti.
Row 3: thinking "?", typing on a PLAIN SILVER LAPTOP WITH NO LOGO, pointing, reading a plain white
document, holding a red page with the letters "PDF", holding a checklist.
Row 4: holding a pink heart, shy, worried with a sweat drop, sad, thumbs-up with a green check,
frustrated with a red ×.
Row 5: sleepy yawn "z", lying asleep, peeking over a ledge, peeking from behind a white door,
listening to PLAIN BLACK HEADPHONES WITH NO LOGO with music notes, holding a PLAIN mug.
No brand marks anywhere.
```

---

## Checklist before committing an image

- [ ] No logo of any company (zoom in on laptop lids, menu bar, icons, avatars).
- [ ] No real person, no realistic face; avatars are initials only.
- [ ] Only fictional names: demo-org, alex-dev, sam-codes, jordan-ui, riley-ops, casey-qa, @demo-user.
- [ ] No real username, email, home-folder path or company name.
- [ ] Only features Zera really has (no "Mentions" tab, no Notion/Slack integrations).
- [ ] Text is legible and spelled right.
- [ ] Captioned as "Illustration" in the README (or replaced by a real screenshot).
