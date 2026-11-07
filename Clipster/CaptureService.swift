import AppKit
import SwiftUI

/// Interactive screen-area capture via the system `screencapture` utility.
///
/// The capture goes to a private temporary file that is read into memory and
/// deleted immediately, on success, cancellation and failure alike. The
/// clipboard is never touched by the capture itself — callers commit results
/// to the clipboard/history only after a successful capture.
final class CaptureService {
    static let shared = CaptureService()

    enum Outcome {
        case image(Data)
        case cancelled
        case failed(String)
    }

    private let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipsterCapture", isDirectory: true)
    private var inFlight = false

    private init() {}

    /// Removes leftover temp files from a previous crash. Call once at launch.
    func cleanupLeftovers() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    func captureInteractive(completion: @escaping (Outcome) -> Void) {
        guard !inFlight else { return }
        inFlight = true
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            inFlight = false
            completion(.failed("Could not create a temporary folder for the capture."))
            return
        }
        let file = tmpDir.appendingPathComponent(UUID().uuidString + ".png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x no sound, PNG to our private temp file.
        proc.arguments = ["-i", "-x", "-t", "png", file.path]
        let errPipe = Pipe()
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] _ in
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self?.inFlight = false
                if let data, !data.isEmpty {
                    completion(.image(data))
                } else if !errText.isEmpty {
                    completion(.failed(errText))
                } else {
                    // No file and no error: the user pressed Escape.
                    completion(.cancelled)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(at: file)
            inFlight = false
            completion(.failed("Could not launch the system screen-capture tool."))
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Small floating confirmation panel (non-activating, auto-dismissing).
/// Used instead of UserNotifications, which are unreliable for ad-hoc-signed apps.
/// All calls must come from the main thread.
final class CaptureHUD {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(symbol: String, title: String, detail: String? = nil,
                     actionTitle: String? = nil, action: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismiss()

        let view = HUDView(symbol: symbol, title: title, detail: detail,
                           actionTitle: actionTitle, action: {
                               action?()
                               dismiss()
                           })
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = hosting.fittingSize
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                         y: f.maxY - size.height - 24))
        }
        panel.orderFrontRegardless()
        Self.panel = panel

        let work = DispatchWorkItem { dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 3.5 : 6.0), execute: work)
    }

    static func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct HUDView: View {
    let symbol: String
    let title: String
    let detail: String?
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detail.map { "\(title). \($0)" } ?? title))
    }
}
