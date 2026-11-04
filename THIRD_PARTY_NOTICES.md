# Third-party notices — Zera 2

## Native Mac app

Zera links WhisperKit 1.1.1 and ArgmaxCore from argmaxinc/WhisperKit for optional on-device dictation. Source: https://github.com/argmaxinc/WhisperKit/tree/v1.1.1. Its MIT license is reproduced below and this notice is included in the app bundle. Models are downloaded separately on request; their model cards and terms apply independently.

AndropKit is local project source under this repository’s MIT license. Package.resolved also pins Apple swift-argument-parser 1.8.2 (Apache-2.0), used by WhisperKit’s CLI target; Zera does not link that CLI or ArgumentParser. Source: https://github.com/apple/swift-argument-parser.

Apple platform frameworks, SF Symbols and system fonts come from the OS/SDK and are not redistributed. SF Symbols are used as app interface glyphs, not as Zera’s identity.

## Android companion

The downloadable debug-signed Androp APK includes the following direct runtime dependencies and their transitives. The exact direct versions are in android/app/build.gradle.kts; dependency source licenses and notices remain applicable.

| Component | Direct version | License | Source |
|---|---|---|---|
| AndroidX Core KTX | 1.13.1 | Apache-2.0 | https://android.googlesource.com/platform/frameworks/support/ |
| AndroidX AppCompat | 1.6.1 | Apache-2.0 | https://android.googlesource.com/platform/frameworks/support/ |
| AndroidX ConstraintLayout | 2.1.4 | Apache-2.0 | https://github.com/androidx/constraintlayout |
| Material Components Android | 1.11.0 | Apache-2.0 | https://github.com/material-components/material-components-android |
| OkHttp / Okio | 4.12.0 / transitive | Apache-2.0 | https://github.com/square/okhttp · https://github.com/square/okio |
| Kotlin standard library / coroutines Android | 1.9.23 / 1.8.0 | Apache-2.0 | https://github.com/JetBrains/kotlin · https://github.com/Kotlin/kotlinx.coroutines |

The Gradle wrapper and Android/Kotlin build plugins are build tools, not Mac app dependencies. Gradle is Apache-2.0. Apache license: https://www.apache.org/licenses/LICENSE-2.0.

## Optional services and tools

Claude Code, Codex, provider APIs, GitHub and weather integrations are separately configured external services; they are not bundled with Zera. Users supply their own installed tools, credentials and permissions. Claude/Codex hooks and observed local activity have different capabilities from managed agent sessions. See docs/PRIVACY_DATA_MAP.md.

## Website and release film

The static website has no third-party JavaScript runtime. The launch film was rendered using Hyperframes/GSAP development tools; those runtimes are not shipped in the Mac app or website. The website ships only the rendered MP4 and images.

Film music: “Happy Beats / Business Moves Vol. 12” by Sascha Ende, https://ende.app/en, licensed CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Edited, trimmed and mixed for the Zera 2 film. UI accents: Kenney interface/impact packs, CC0. Full media credits and capture provenance: docs/MEDIA.md and docs/media/v2/audio-credits.txt. These music rights are separate from the code license.

Fresh v2 app screenshots use fictional fixture data. The phone gallery artwork is synthetic project-created scenery. Older illustrations remain historical assets and are no longer the lead README/site screenshots. Zera’s character, icon and original creative assets retain LICENSE-ASSETS.md terms. No third-party font files are bundled.

CI uses pinned actions/checkout, actions/upload-artifact and softprops/action-gh-release. Their source repositories contain their respective MIT licenses. Xcode and native signing/packaging tools are not redistributed.

## WhisperKit license

MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Names and marks

Zera is independent of Anthropic, OpenAI, GitHub, Apple and Samsung. Product names and marks belong to their respective owners; their appearance describes interoperability and does not imply endorsement.
