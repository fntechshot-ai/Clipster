import SwiftUI
import AppKit
import Carbon
import Carbon.HIToolbox

@main
struct ClipsterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.manager)
                .environmentObject(appDelegate.shortcuts)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let manager = ClipboardManager()
    let shortcuts = ShortcutManager()
    var lastActiveApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Popover setup
        popover.contentSize = NSSize(width: 460, height: 560)
        popover.behavior = .transient
        let host = NSViewController()
        host.view = NSHostingView(rootView: ContentView().environmentObject(manager))
        popover.contentViewController = host

        // Menu bar item: left click toggles the popover, right click shows a menu.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipster")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Start clipboard watcher
        manager.start()

        // Remove capture temp files a crash might have left behind.
        CaptureService.shared.cleanupLeftovers()

        // Global hotkeys: history popover (fixed ⌥⌘V) + configurable capture shortcuts.
        HotKeyCenter.shared.register(
            id: HotKeyCenter.historyHotKeyID,
            spec: HotKeySpec(keyCode: UInt32(kVK_ANSI_V),
                             carbonModifiers: UInt32(cmdKey) | UInt32(optionKey))
        ) { [weak self] in
            self?.togglePopover()
        }
        shortcuts.onCaptureArea = { [weak self] in self?.captureArea() }
        shortcuts.onCaptureText = { [weak self] in self?.captureText() }
        shortcuts.activate()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handlePasteNow), name: .clipsterPasteNow, object: nil)
        nc.addObserver(self, selector: #selector(captureAreaNotification), name: .clipsterCaptureArea, object: nil)
        nc.addObserver(self, selector: #selector(captureTextNotification), name: .clipsterCaptureText, object: nil)
        nc.addObserver(self, selector: #selector(openSettings), name: .clipsterOpenSettings, object: nil)
    }

    // MARK: - Status item

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let area = NSMenuItem(title: "Capture Area", action: #selector(captureAreaNotification), keyEquivalent: "")
        area.target = self
        if let spec = shortcuts.captureAreaSpec {
            area.title = "Capture Area (\(spec.displayString))"
        }
        menu.addItem(area)

        let text = NSMenuItem(title: "Capture Text", action: #selector(captureTextNotification), keyEquivalent: "")
        text.target = self
        if let spec = shortcuts.captureTextSpec {
            text.title = "Capture Text (\(spec.displayString))"
        }
        menu.addItem(text)

        menu.addItem(.separator())
        let history = NSMenuItem(title: "Open History (⌥⌘V)", action: #selector(togglePopover), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Clipster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // remember the app that was frontmost before showing Clipster
            lastActiveApp = NSWorkspace.shared.frontmostApplication
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        popover.performClose(nil)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    // MARK: - Screen capture

    @objc private func captureAreaNotification() { captureArea() }
    @objc private func captureTextNotification() { captureText() }

    /// Capture a screen selection as an image: clipboard + one history item.
    func captureArea() {
        hideUIThen { [weak self] in
            CaptureService.shared.captureInteractive { outcome in
                guard let self else { return }
                switch outcome {
                case .cancelled:
                    break // clipboard and history untouched
                case .failed(let message):
                    self.showCaptureFailure(message)
                case .image(let png):
                    let id = self.manager.storeCapturedImage(png)
                    if id != nil {
                        CaptureHUD.show(symbol: "checkmark.circle",
                                        title: "Image copied to clipboard",
                                        detail: "Saved to history — paste anywhere with ⌘V.")
                    } else {
                        CaptureHUD.show(symbol: "checkmark.circle",
                                        title: "Image copied to clipboard",
                                        detail: "History is paused, so it was not saved.")
                    }
                }
            }
        }
    }

    /// Capture a screen selection as text: OCR in memory first, then commit
    /// text to the clipboard and the source image (once) to history.
    func captureText() {
        hideUIThen { [weak self] in
            CaptureService.shared.captureInteractive { outcome in
                guard let self else { return }
                switch outcome {
                case .cancelled:
                    break // clipboard and history untouched
                case .failed(let message):
                    self.showCaptureFailure(message)
                case .image(let png):
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = OCRService.recognize(pngData: png)
                        DispatchQueue.main.async {
                            self.finishCaptureText(result, png: png)
                        }
                    }
                }
            }
        }
    }

    private func finishCaptureText(_ result: OCRService.RecognitionResult, png: Data) {
        switch result {
        case .text(let text):
            let id = manager.storeCapturedText(text, sourcePNG: png)
            let preview = text.replacingOccurrences(of: "\n", with: " ")
            if let id {
                CaptureHUD.show(symbol: "text.viewfinder",
                                title: "Text copied to clipboard",
                                detail: String(preview.prefix(90)),
                                actionTitle: "Review") { [weak self] in
                    self?.showDetail(id)
                }
            } else {
                CaptureHUD.show(symbol: "text.viewfinder",
                                title: "Text copied to clipboard",
                                detail: "History is paused, so the source image was not saved.")
            }
        case .noText:
            CaptureHUD.show(symbol: "textformat.slash",
                            title: "No text found",
                            detail: "Your clipboard was left unchanged.")
        case .failed(let category):
            CaptureHUD.show(symbol: "exclamationmark.triangle",
                            title: "Text recognition failed",
                            detail: "\(category). Your clipboard was left unchanged.")
        }
    }

    private func showCaptureFailure(_ message: String) {
        CaptureHUD.show(symbol: "exclamationmark.triangle",
                        title: "Screen capture failed",
                        detail: message + " If this is a permission problem, allow Clipster under Screen Recording.",
                        actionTitle: "Open Settings") {
            CaptureService.openScreenRecordingSettings()
        }
    }

    /// Hides Clipster's own UI so it never appears in the capture, then runs `work`.
    private func hideUIThen(_ work: @escaping () -> Void) {
        popover.performClose(nil)
        CaptureHUD.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func showDetail(_ id: UUID) {
        manager.detailItemID = id
        if !popover.isShown { togglePopover() }
    }

    // MARK: - Paste simulation

    @objc private func handlePasteNow() {
        // 1) close our UI
        popover.performClose(nil)

        // 2) bring focus back to the app user had open
        if let app = lastActiveApp {
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            NSApp.deactivate()
        }

        // 3) press ⌘V after a tiny delay so focus is restored
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
