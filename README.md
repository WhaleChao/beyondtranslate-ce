# BeyondTranslate CE

[![GitHub release](https://img.shields.io/github/release/beyondtranslate/beyondtranslate-ce/all.svg?style=flat-square)](https://github.com/beyondtranslate/beyondtranslate-ce/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/beyondtranslate/beyondtranslate-ce/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/beyondtranslate/beyondtranslate-ce/actions/workflows/ci.yml)

**BeyondTranslate CE** is the open-source community edition of **BeyondTranslate** (formerly **Biyi**), a fast, native-feeling translation app for macOS, Windows and Linux. Capture text from anywhere on screen and translate it with the engine of your choice, from a lightweight app that stays out of your way until you need it. [View the documentation](https://beyondtranslate.com/docs/)

The UI is Flutter; the core services (settings, translation, OCR, dictionary) are Rust, reached through generated FFI bindings; on macOS the Settings window is native SwiftUI.

---

English | [简体中文](./README-ZH.md)

---

![](https://beyondtranslate.com/images/screenshots/biyi_extract_text_from_screen_selection.gif)

## Platform Support

| Linux | macOS | Windows |
| :---: | :---: | :-----: |
|   ✔️   |   ✔️   |    ✔️    |

## Installation

Downloads for all three platforms are on the [Releases](https://github.com/beyondtranslate/beyondtranslate-ce/releases/latest) page. The [website](https://beyondtranslate.com/release-notes) lists other installation methods and the release notes.

**macOS, with Homebrew:**

```bash
brew install --cask beyondtranslate/tap/beyondtranslate-ce
```

> **macOS, from the DMG:** the app is not notarized yet, so macOS refuses to open a freshly downloaded copy. Homebrew clears that for you; after a manual install, run this once:
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/BeyondTranslate-CE.app"
> ```

**Linux:** the `.deb` declares what it needs (GTK 3, X11 and XInput, which every desktop installation has). The AppImage expects the same libraries on the system.

## Development

### Prerequisites

- **Flutter**, stable channel. CI builds with 3.47.5.
- **Rust**, stable toolchain. Flutter's native-assets hook compiles the Rust runtime when the app builds.
- **Python 3**, for the scripts under `scripts/`.
- **Linux only**, the Flutter desktop toolchain plus the headers the native window layer builds against:

  ```bash
  sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libx11-dev libxi-dev
  ```

### Set up

```bash
git clone https://github.com/beyondtranslate/beyondtranslate-ce.git
cd beyondtranslate-ce
dart pub get
dart run melos bootstrap
```

### Run

```bash
cd apps/desktop/flutter
flutter run -d macos   # or linux / windows
```

### Check

```bash
dart run melos run analyze
dart run melos run test
cargo test --workspace
python3 scripts/format.py --check
```

[AGENTS.md](./AGENTS.md) describes the repository layout, the Flutter ↔ Rust bridge and the code-generation workflow in detail.

## Discussion

> Join the group to share suggestions and ideas.

- [QQ Group](https://jq.qq.com/?_wv=1027&k=vYQ5jW7y)

## Related Links

- [nativeapi](https://github.com/libnativeapi/nativeapi), the native window, tray and shortcut layer
- [dazzui](https://github.com/dazzlabs/dazzui), the Flutter design system
- [Fastforge](https://github.com/fastforgedev/fastforge), which packages the releases

## License

[AGPL](./LICENSE)
