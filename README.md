# Retron Commander

Retron Commander is an open source fan project: a native macOS file manager inspired by classic two-panel commander apps. It combines a keyboard-focused, dual-pane workflow with familiar macOS presentation and an optional Norton Commander-style DOS theme. The project is independent and is not affiliated with or endorsed by any other software or hardware company; all third-party trademarks belong to their owners.

## Features

- **Two-panel file management**: browse folders and volumes side by side, select items, and copy, move, rename, delete, or create folders with keyboard shortcuts and function-key commands.
- **Files and archives**: create and browse common archives, inspect disk images, split and join files, calculate checksums, and compare folders or files.
- **Find and organize**: search files, find duplicates, batch rename, inspect file properties, and recover items from Trash.
- **Built-in tools**: view text and multimedia files, edit property lists, inspect PE metadata, view DBF tables, and encode or decode MIME and BinHex data.
- **Network and automation**: connect to SMB locations and FTP profiles, and run user menu commands or scripts.
- **Themes and controls**: choose the native-style default or the DOS-inspired Norton Commander theme; configure function-key actions and whether the Mac function keys send F1–F12 directly while the app is active.
- **Disk map**: visualize folder sizes, open a folder in Retron Commander, or reveal it in Finder.

## Requirements

- macOS 14 or later
- Apple Silicon (arm64) or Intel (x86_64) Mac
- Xcode command line tools with the Swift 6 toolchain to build from source

## Build and run

```sh
swift build --configuration release
Scripts/package-app.sh
open ".build/Retron Commander.app"
```

The packaging script builds a universal app for Apple Silicon and Intel, along with the bundled 7-Zip helper. The app is ad-hoc signed for local use; it does not have a Developer ID signature and is not notarized.

## Install

Download the latest universal disk image from the [Releases page](https://github.com/konzertblock/retron-commander/releases), open it, and drag Retron Commander to Applications. Because the app is not notarized, macOS may block its first launch. To open it, Control-click the app in Finder, choose **Open**, then confirm. Sparkle checks for updates and verifies update archives with an EdDSA signature.

## Release assets

Each release provides the universal macOS DMG, a Sparkle-signed update archive and its appcast, and GitHub's automatically generated source archives. The DMG itself is unsigned and the app is not notarized.

Maintainers can prepare the appcast and update archive with:

```sh
APP_VERSION=1.0 BUILD_NUMBER=1 Scripts/make-release-assets.sh
```

This writes the ZIP and `appcast.xml` under `.build/release/1.0/`. The Sparkle EdDSA private key is kept in the maintainer's local macOS Keychain under the `retron-commander` account; it is never stored in this repository. The public key is embedded in the app.

## Project layout

- `Sources/RetronCommander`: the macOS app and its file management, archive, search, viewer, network, and theme features.
- `Sources/RetronCopyFile`: the native file-copy helper.
- `Assets`: app artwork.
- `Scripts`: app packaging, release preparation, and focused verification helpers.
- `ThirdParty`: version-pinned 7-Zip source and third-party license notices.

## License

Retron Commander's original source is available under the MIT License; see [LICENSE](LICENSE). The app also includes third-party components with their own terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the bundled license files for details.
