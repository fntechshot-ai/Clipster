import SwiftUI
import AppKit
import Carbon
import Carbon.HIToolbox

extension Notification.Name {
    static let clipsterPasteNow = Notification.Name("clipsterPasteNow")
}
struct SettingsView: View {
    @EnvironmentObject var manager: ClipboardManager

    var body: some View {
        Form {
            Toggle("Capture clipboard changes", isOn: $manager.isCapturing)
            Toggle("Ignore passwords (from password managers)", isOn: $manager.ignorePasswords)
                .help("When on, items that apps mark as concealed (e.g. passwords) are not saved to history.")
            Stepper(value: $manager.maxItems, in: 20...1000) {
                Text("Max history: \(manager.maxItems)")
            }
        }
        .padding()
        .frame(width: 380, height: 170)
    }
}

@main
struct ClipsterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView().environmentObject(appDelegate.manager) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let manager = ClipboardManager()
    var lastActiveApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Popover setup
        popover.contentSize = NSSize(width: 460, height: 560)
        popover.behavior = .transient
        let host = NSViewController()
        host.view = NSHostingView(rootView: ContentView().environmentObject(manager))
        popover.contentViewController = host

        // Menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Start clipboard watcher
        manager.start()

        // Global hotkey: ⌥⌘V
        HotKey.register(modifiers: [.option, .command], key: UInt32(kVK_ANSI_V)) { [weak self] in
            self?.togglePopover()
        }

        // Listen for "paste now" requests from ClipboardManager
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handlePasteNow),
                                               name: .clipsterPasteNow,
                                               object: nil)
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
