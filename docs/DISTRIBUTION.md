# Zera distribution checklist

## 1. Make the existing download easy

- [x] Release v0.1.8 on GitHub with a DMG, ZIP and checksums.
- [x] Prepare site buttons that resolve the latest DMG, with the release page as a fallback.
- [x] Prepare first-launch help: Applications, Privacy & Security → Open Anyway, and an optional scoped Terminal command.
- [x] Include an offline install guide in future DMGs.
- [x] Make future release notes distinguish signing from successful notarization.
- [ ] Commit and deploy the installation updates. Existing v0.1.8 artifacts are unchanged.
- [x] Add the MIT License.

## 2. Remove the unsigned-app installation barrier

Recommended public distribution: Developer ID signing + Apple notarization + the existing DMG.
Users still get the normal downloaded-app confirmation, but should not need an unidentified-developer override on a normally configured Mac.

- [ ] Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/) or use an existing membership. Apple lists USD 99/year, with regional pricing.
- [ ] Create a **Developer ID Application** certificate and export a password-protected P12.
- [ ] Configure these **GitHub repository secrets**, never source files:
  - `MACOS_CERTIFICATE`: base64-encoded P12.
  - `MACOS_CERTIFICATE_PASSWORD`: the P12 password.
  - `CODESIGN_IDENTITY`: the full Developer ID Application identity.
  - `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`: notarization credentials.
- [ ] Release a new version using the existing release workflow. It signs the app, notarizes and staples the app and DMG, then publishes checksums.
- [ ] Test a browser-downloaded release on a Mac without a prior Zera approval, including launch, integrations and permissions. A local build does not exercise download quarantine.

Reference: [Apple's Developer ID distribution guide](https://developer.apple.com/developer-id/).

## 3. Add convenient installs and updates

- [ ] Publish a maintained Homebrew cask in a custom tap. Suggested repository: `amsynist/homebrew-tap`; proposed command: `brew install --cask amsynist/tap/zera`. This command is not available yet. Homebrew is an additional install channel, not a replacement for notarization.
- [ ] Add in-app updates, with signed update archives and release verification. [Sparkle](https://sparkle-project.org/) is an established native macOS option; it is not integrated yet.

Reference: [Homebrew custom taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap).

## 4. Reach users

- [ ] Keep the website as the main landing page and GitHub Releases as the download host.
- [ ] Launch on [Product Hunt](https://www.producthunt.com/launch) with the demo reel and installation guide.
- [ ] Submit a [Show HN](https://news.ycombinator.com/showhn.html) with a working download and the story behind Zera. Be available to answer questions.
- [ ] Consider a Mac App Store edition after reviewing sandbox compatibility for CLI execution, hooks, repo access and system integrations. Feature changes may be necessary; this has not been audited yet.

[Coucou](https://github.com/Louis-CFM/coucou#install) currently offers its Mac ZIP through GitHub Releases and describes a separate sandboxed App Store edition as coming soon, with some features retained only in its GitHub build.
