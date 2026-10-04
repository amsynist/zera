# Third-Party Notices — Zera

Inventory of third-party components and content. It is not legal advice; check each licence at its source.

## 1. Packages compiled into Zera

**None.** `Package.swift` declares one executable target and one test target with **no package
dependencies**. There is no `Package.resolved`, and no CocoaPods, Carthage, npm, Python, Go or
vendored source. Nothing third-party is compiled into the app.

| Package | Version | License | Source | Required attribution | Redistribution obligations | Modification requirements | Notice requirements |
|---|---|---|---|---|---|---|---|
| *(none)* | — | — | — | — | — | — | — |

## 2. Platform frameworks (linked, not redistributed)

These come from Apple's SDK under the Xcode and Apple Developer agreements. Zera links to them and does
not redistribute them.

| Component | Use in Zera | Notes |
|---|---|---|
| AppKit, Foundation, EventKit, PDFKit, QuickLook / QuickLookThumbnailing, Security (Keychain), ServiceManagement, CoreText, XCTest | UI, calendar, PDFs, thumbnails, Keychain, login item, tests | System frameworks; no bundled copies |
| SF Symbols (via `NSImage(systemSymbolName:)`) | UI glyphs | Used through the system API only; not bundled. Apple's SF Symbols terms limit use to app UI on Apple platforms and forbid using them in app icons, logos or trademarks. Zera's app icon is its own art. |
| System fonts (SF Pro / SF Mono, via `NSFont.systemFont`) | UI text | Not bundled or redistributed. |

## 3. Build and CI tools (not shipped in the app)

| Tool / Action | Version referenced | License | Source | Obligations |
|---|---|---|---|---|
| actions/checkout | v4.4.0 (pinned by commit SHA) | MIT | github.com/actions/checkout | None for users of the action |
| actions/upload-artifact | v4.6.2 (pinned by commit SHA) | MIT | github.com/actions/upload-artifact | Same |
| softprops/action-gh-release | v2.6.2 (pinned by commit SHA) | MIT | github.com/softprops/action-gh-release | Same; it runs with `contents: write` in the release job only |
| Xcode / Swift toolchain, `codesign`, `notarytool`, `stapler`, `hdiutil`, `ditto`, `sips`, `iconutil` | runner-provided | Apple licences | macOS runner | Not redistributed |

There are no `curl | sh` or `wget | sh` patterns, downloaded installers or remote scripts in the build.

## 4. External software Zera talks to at runtime (not bundled)

| Software | Relationship | Notes |
|---|---|---|
| Claude Code CLI (`claude`), Anthropic | Optional. The user installs it; Zera runs it as a subprocess (print mode) and installs documented Claude Code hooks in `~/.claude/settings.json` | Proprietary to Anthropic; governed by the user's own Anthropic terms. Zera neither bundles nor redistributes it, and does not read its credentials. |
| Anthropic Messages API | Optional API-key mode | The user's key, the user's terms |
| GitHub REST API | Optional | The user's token; GitHub Terms of Service and API terms |

## 5. Third-party text and data in the repository

| File | Content | Source indicator | Risk / action |
|---|---|---|---|
| `Tests/ZeraTests/ClaudeCLITests.swift` | Short excerpt of `claude --help` output (flag names) | Anthropic CLI output | Interoperability test fixture |
| `Tests/ZeraTests/ClaudeCodeOutputParserTests.swift` | JSON event shapes "copied from a real `claude -p … stream-json` run, trimmed" | Anthropic CLI output format | Sanitised (`/tmp`, `abc-123`, `/Users/me`); data-format fixtures |

No third-party copyright headers, SPDX tags, licence texts or vendored code were found in any file
or in any historical revision.

## 6. Images and artwork

| Asset group | Origin | Third-party marks | Notes |
|---|---|---|---|
| `Resources/Sprites/*.png` (shipped in the app) | AI-assisted artwork of the Zera character (see `Resources/CARD_SPRITE_PROMPT.md`); some files carry C2PA "Anthropic Files" provenance metadata | None — the laptop in `laptop.png`, `card_laptop_side.png`, `focused.png` was retouched to remove a brand mark | Original project artwork |
| App icon (rendered at build time by `Tools/MakeIcon.swift`) | Programmatic, from the sprites | None | — |
| GitHub mark | **Not shipped.** The PR screen uses a generic glyph | — | — |
| Fonts | None bundled (system fonts via API) | — | — |

## 7. Trademark and affiliation notice

Zera is an independent open-source project. It is not affiliated with, endorsed by, or sponsored by
Anthropic, GitHub, or Apple. Claude and Claude Code are trademarks of Anthropic, PBC. GitHub is a
trademark of GitHub, Inc. Apple, Mac, macOS and Finder are trademarks of Apple Inc., registered in
the U.S. and other countries. Other names may be trademarks of their respective owners.
