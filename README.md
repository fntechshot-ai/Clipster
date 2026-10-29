# Clipster

A lightweight macOS **menu bar clipboard history** app, written in Swift + SwiftUI.

- 📋 Keeps a searchable history of what you copy (text, HTML, images, files)
- 📌 **Pin** important items and **Clear Unpinned** the rest
- 🔤 **Paste as Plain Text**
- 🖼️ Thumbnails & type badges (TXT / HTML / IMG / FILE)
- ⌥⌘V global hotkey to open the history popover
- 🔒 Optional "Ignore passwords" mode that skips items marked as concealed by password managers
- 💾 History persists locally in `~/Library/Application Support/Clipster/history.json`

Requires **macOS 13+**.

## Build

### Option A — without Xcode (Command Line Tools only)

If you only have the Xcode Command Line Tools installed (`xcode-select --install`):

```bash
./build_noxcode.sh      # produces dist/Clipster.app
cp -R dist/Clipster.app /Applications/
```

This compiles the sources with `swiftc` and assembles the `.app` bundle directly
(no full Xcode required).

### Option B — with Xcode

1. Open `Clipster.xcodeproj` in Xcode and set your Signing Team.
2. Or run:
   ```bash
   ./build.sh          # builds via xcodebuild into dist/
   ./make_dmg.sh       # optional: package a DMG
   ```

## First run

Because the app simulates a ⌘V keystroke to paste into the app you were using,
macOS will ask for **Accessibility** permission:

> System Settings → Privacy & Security → Accessibility → enable **Clipster**

## Launch at login

The simplest way is a LaunchAgent:

```bash
cat > ~/Library/LaunchAgents/com.francisconeto.Clipster.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.francisconeto.Clipster</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>/Applications/Clipster.app</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl load ~/Library/LaunchAgents/com.francisconeto.Clipster.plist
```

## Privacy

Clipster stores its history **only on your Mac**. Nothing is sent anywhere.
Enable "Ignore passwords" in Settings if you don't want concealed clipboard
items saved to history.

## License

[MIT](LICENSE)
