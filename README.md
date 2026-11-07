# Clipster

A lightweight macOS **menu bar clipboard history** app, written in Swift + SwiftUI.

- 📋 Keeps a searchable history of what you copy (text, HTML, images, files)
- 🔎 **OCR**: text in copied images is recognized locally (Apple Vision) and becomes **searchable**
- 📸 **Capture Area** (⌥⌘4): select a screen region → image lands on the clipboard + history
- 📝 **Capture Text** (⌥⌘5): select a screen region → its **text** lands on the clipboard, ready to paste
- ✨ Optional **local AI actions** (translate / summarize / rewrite / explain / analyze image) via [Ollama](https://ollama.com) — fully offline-capable, disabled until configured
- 📌 **Pin** important items and **Clear Unpinned** the rest
- 🔤 **Paste as Plain Text**
- 🖼️ Thumbnails & type badges (TXT / HTML / IMG / FILE)
- ⌥⌘V global hotkey to open the history popover; capture shortcuts are configurable in Settings → Capture
- 🔒 Optional "Ignore passwords" mode that skips items marked as concealed by password managers
- 💾 History persists locally in `~/Library/Application Support/Clipster/history.json`

Requires **macOS 13+**. Everything — clipboard history, OCR, screen capture — works **offline with no account and no LLM installed**; the AI actions are an optional extra.

## Install (download)

1. Grab `Clipster.dmg` from the [latest release](https://github.com/fntechshot-ai/Clipster/releases/latest).
2. Open the DMG and drag **Clipster** into **Applications**.
3. The app is **ad-hoc signed** (no paid Apple Developer certificate), so on first
   launch macOS Gatekeeper will warn it's from an "unidentified developer".
   To open it:
   - **Right-click** `Clipster.app` → **Open** → **Open**, or
   - run once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Clipster.app
     ```

Prefer to build it yourself? See [Build](#build) below.

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

### Tests

Automated tests (data model, OCR queue, search, clipboard coordination, AI
client parsing) run as a plain compiled test binary — no Xcode required:

```bash
./run_tests.sh
```

## First run

Because the app simulates a ⌘V keystroke to paste into the app you were using,
macOS will ask for **Accessibility** permission:

> System Settings → Privacy & Security → Accessibility → enable **Clipster**

The first time you use **Capture Area** or **Capture Text**, macOS will ask for
**Screen Recording** permission (the system `screencapture` tool is used, so the
native selection UI, Retina and multi-display handling all behave like ⇧⌘4):

> System Settings → Privacy & Security → Screen Recording → enable **Clipster**

Clipboard OCR never needs Screen Recording permission — only the capture
commands do. Captures never create files on your Desktop; they go straight to
the clipboard and history.

## OCR (text in images)

New images in history are OCR'd automatically (one at a time, in the
background, locally via Apple Vision). You can:

- turn automatic OCR off in **Settings → OCR** (manual *Extract Text* stays available),
- run a cancellable **“Extract text from existing images”** backfill for older history,
- search for words that appear only inside screenshots,
- open an item's detail panel to view/copy the recognized text.

Recognition favours Portuguese, English and Spanish, with automatic language
detection where supported. OCR text never replaces your clipboard on its own —
only the explicit *Copy Text* / *Capture Text* actions write text to the
clipboard.

## Local AI actions (optional)

Clipster can run **translate / summarize / rewrite / explain / custom
instruction** on text items (and on text extracted from images), plus
**Analyze Image** with follow-up questions — all against a **local** model
server. There is no cloud fallback, no bundled API key and no automatic model
download.

Setup:

1. Install [Ollama](https://ollama.com) and pull a model, e.g.
   `ollama pull gemma2:9b` (text) and/or `ollama pull qwen2.5vl:7b` (vision,
   needed for *Analyze Image*).
2. In **Settings → AI**: enable AI actions, test the connection
   (default endpoint `http://127.0.0.1:11434`) and pick your models.

Only loopback endpoints are accepted, redirects off loopback are refused and
models that proxy to a cloud backend (names like `…-cloud`) are excluded from
the pickers. Content is only ever sent when you explicitly run an action, and
only the selected item's content — never your whole history.

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

Clipster stores its history **only on your Mac**. Nothing is sent anywhere:
OCR and screen capture are fully local, and the optional AI actions talk only
to a loopback endpoint on your machine, only when you explicitly trigger them.
If your local server proxies certain models to a cloud backend, Clipster
excludes the known ones (`…-cloud`), but it cannot audit arbitrary server
configurations — keep your local server local. Enable "Ignore passwords" in
Settings if you don't want concealed clipboard items saved to history. While
clipboard capture is paused, the capture commands still write to the clipboard
but save nothing to history.

## License

[MIT](LICENSE)
