# Contributing to Clipster

Thanks for your interest! Clipster is a small, self-contained SwiftUI macOS app.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools (`xcode-select --install`) — a full Xcode install is **not** required

## Build & run locally

```bash
git clone https://github.com/fntechshot-ai/Clipster.git
cd Clipster
./build_noxcode.sh            # compiles with swiftc, produces dist/Clipster.app
cp -R dist/Clipster.app /Applications/
open /Applications/Clipster.app
```

To package a DMG: `./make_dmg.sh` → `dist/Clipster.dmg`.

If you have full Xcode, you can instead open `Clipster.xcodeproj` or run `./build.sh`.

## Project layout

```
Clipster/
  ClipsterApp.swift        # @main app, menu-bar status item, popover, ⌥⌘V hotkey, auto-paste
  ClipboardManager.swift   # polls NSPasteboard, stores history, pin/delete/search, persistence
  ContentView.swift        # SwiftUI list UI (rows, thumbnails, type badges)
  HotKey.swift             # Carbon global hotkey wrapper
  Info.plist               # LSUIElement (menu-bar only), min macOS 13
  Assets.xcassets/         # app icon
build_noxcode.sh           # swiftc + iconutil build (no Xcode)
build.sh / make_dmg.sh     # Xcode build / DMG packaging
```

History is stored at `~/Library/Application Support/Clipster/history.json`.
User settings are stored in `UserDefaults`.

## Guidelines

- Match the existing code style (no external dependencies — system frameworks only).
- Keep it a single-window, menu-bar app; avoid adding heavy frameworks.
- Test a clean build with `./build_noxcode.sh` before opening a PR.
- CI (GitHub Actions) builds every push/PR on a macOS runner.

## Releasing (maintainers)

Push a tag to build and attach a DMG to a GitHub Release automatically:

```bash
git tag v1.0.0
git push origin v1.0.0
```
