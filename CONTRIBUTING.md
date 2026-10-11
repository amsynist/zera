# Contributing to Zera

Thanks for helping improve Zera. Integrations, character expressions, sounds, accessibility improvements and bug fixes are welcome.

## Report a bug or suggest a feature

Open an [issue](https://github.com/amsynist/zera/issues). For bugs, include your macOS version, Zera version, steps to reproduce and what you expected to happen. Remove private paths, tokens and other sensitive information from logs.

Report security issues privately using [SECURITY.md](SECURITY.md).

## Make a change

1. Fork the repository and create a branch for your change.
2. Keep the change focused. For larger features, discuss the approach in an issue first.
3. Use existing shared typography, spacing, theme colors and controls. Preserve the app's manual AppKit layout approach.
4. Keep optional integrations optional and protect local data. Never commit credentials or `.env` files.
5. Build and check the affected behavior:

   ```sh
   ./build.sh
   swift test
   open dist/Zera.app
   ```

6. Open a pull request explaining what changed, why, and how you verified it. For UI changes, check the affected screen, keyboard interactions and neighboring layouts locally.

You need macOS 13 or newer and the Xcode Command Line Tools. There are no third-party Swift package dependencies.

## Licensing

Code contributions are made under the project's [MIT License](LICENSE). Zera's name, character and original creative assets have separate terms in [LICENSE-ASSETS.md](LICENSE-ASSETS.md). When contributing artwork or sounds, state their origin and the permission you have to contribute them. Preserve third-party notices.
