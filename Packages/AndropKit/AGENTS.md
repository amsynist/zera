# Native sharing core

The root AGENTS.md and docs/ANDROID_PROTOCOL.md apply. This is Zera’s self-contained local Swift package, using AppKit/SwiftUI, Network and CryptoKit, with no helper process. Keep Android wire compatibility, peer ownership, bounded streaming, byte/path safety and final verified persistence ACK intact. There is no cloud transport or fixed v3 file cap; legacy base64 compatibility alone is limited to 8 MiB.

The host chooses a display and landing point, and enables swallowsAtLanding: ordinary files are absorbed into Zera’s existing island. Photos, video and supported text can instead land/open after verification; the card makes way before opening. Respect actual preview aspect ratios and the shared split from the phone. All disk/preview work stays off main; UI lifecycle and native compositor changes stay on main.

Cached textures and vector/Core Animation motion are required. Do not restore per-frame full-screen SwiftUI blur/gradient rebuilding. Delayed callbacks are keyed by ID/generation; stop and Reduce Motion must remove loops. Only verified files reach Shelf. Run `swift test --package-path Packages/AndropKit`. Keep this package, the Kotlin sender and the protocol docs synchronized; do not overwrite newer code with a stale external export.
