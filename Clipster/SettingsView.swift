import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var manager: ClipboardManager
    @EnvironmentObject var shortcuts: ShortcutManager

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            // The OCR service is passed directly so the tab observes it
            // (nested ObservableObjects don't propagate through SwiftUI).
            OCRSettingsTab(ocr: manager.ocr)
                .tabItem { Label("OCR", systemImage: "text.viewfinder") }
            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 480)
        .padding()
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var manager: ClipboardManager

    var body: some View {
        Form {
            Toggle("Capture clipboard changes", isOn: $manager.isCapturing)
            Text("While capture is off, Capture Area / Capture Text still copy to the clipboard but do not save anything to history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Ignore passwords (from password managers)", isOn: $manager.ignorePasswords)
                .help("When on, items that apps mark as concealed (e.g. passwords) are not saved to history.")
            Stepper(value: $manager.maxItems, in: 20...1000) {
                Text("Max history: \(manager.maxItems)")
            }
        }
        .padding()
    }
}

struct OCRSettingsTab: View {
    @EnvironmentObject var manager: ClipboardManager
    @ObservedObject var ocr: OCRService

    var body: some View {
        Form {
            Toggle("Automatically extract text from new images", isOn: $manager.autoOCR)
            Text("Recognition runs locally with Apple Vision. Recognized text makes images searchable; it never replaces the clipboard on its own. Languages: Portuguese, English, Spanish (auto-detected where supported).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if ocr.backfillRunning {
                HStack {
                    ProgressView(value: Double(ocr.backfillDone), total: Double(max(ocr.backfillTotal, 1)))
                    Text("\(ocr.backfillDone) of \(ocr.backfillTotal)")
                        .font(.caption)
                        .monospacedDigit()
                    Button("Cancel") { ocr.cancelBackfill() }
                }
            } else {
                Button("Extract text from existing images") { ocr.startBackfill() }
                    .help("Runs OCR on images already in history that have no cached text. One image at a time; already-processed images are skipped.")
            }
        }
        .padding()
    }
}

struct CaptureSettingsTab: View {
    @EnvironmentObject var shortcuts: ShortcutManager

    var body: some View {
        Form {
            ShortcutRecorderRow(title: "Capture Area shortcut", spec: $shortcuts.captureAreaSpec,
                                defaultSpec: ShortcutManager.defaultAreaSpec)
            ShortcutRecorderRow(title: "Capture Text shortcut", spec: $shortcuts.captureTextSpec,
                                defaultSpec: ShortcutManager.defaultTextSpec)
            Text("Capturing the screen needs the macOS Screen Recording permission the first time it is used. Clipboard OCR never needs it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Screen Recording settings…") {
                CaptureService.openScreenRecordingSettings()
            }
        }
        .padding()
    }
}

/// Minimal shortcut recorder: click, press a combo (needs ⌘, ⌃ or ⌥), Esc cancels.
struct ShortcutRecorderRow: View {
    let title: String
    @Binding var spec: HotKeySpec?
    let defaultSpec: HotKeySpec

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press shortcut… (Esc cancels)" : (spec?.displayString ?? "Disabled"))
                    .frame(minWidth: 140)
            }
            .accessibilityLabel(recording ? "Recording shortcut, press keys now" : "\(title): \(spec?.displayString ?? "disabled"), click to change")
            if spec != nil {
                Button {
                    stopRecording()
                    spec = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Disable this shortcut")
                .accessibilityLabel("Disable shortcut")
            } else {
                Button("Default") {
                    stopRecording()
                    spec = defaultSpec
                }
                .help("Restore the default shortcut (\(defaultSpec.displayString))")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let mods = HotKeySpec.carbonModifiers(from: flags)
            // Require at least one non-shift modifier so plain typing can't be captured.
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                NSSound.beep()
                return nil
            }
            spec = HotKeySpec(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

struct AISettingsTab: View {
    @ObservedObject var config = AIConfig.shared
    @State private var models: [AIModel] = []
    @State private var statusMessage: String?
    @State private var testing = false

    var body: some View {
        Form {
            Toggle("Enable local AI actions", isOn: $config.enabled)
            Text("AI actions run on demand against a local model server (Ollama). Nothing is sent anywhere until you explicitly run an action, and only the selected item's content is sent — never the whole history.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Server endpoint", text: $config.endpoint, prompt: Text(OllamaClient.defaultEndpoint))
                .disableAutocorrection(true)
                .accessibilityLabel("Local AI server endpoint")
            if !config.endpoint.isEmpty, OllamaClient(endpoint: config.endpoint) == nil {
                Label("Only loopback endpoints are accepted (http://127.0.0.1:… or http://localhost:…).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Test connection & refresh models") { testConnection() }
                    .disabled(testing || OllamaClient(endpoint: config.endpoint) == nil)
                if testing { ProgressView().controlSize(.small) }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Picker("Text model", selection: $config.textModel) {
                Text("None").tag("")
                ForEach(models) { m in
                    Text(m.name).tag(m.name)
                }
                if !config.textModel.isEmpty && !models.contains(where: { $0.name == config.textModel }) {
                    Text(config.textModel).tag(config.textModel)
                }
            }
            Picker("Vision model (image analysis)", selection: $config.visionModel) {
                Text("None").tag("")
                ForEach(models.filter(\.supportsVision)) { m in
                    Text(m.name).tag(m.name)
                }
                if !config.visionModel.isEmpty && !models.contains(where: { $0.name == config.visionModel }) {
                    Text(config.visionModel).tag(config.visionModel)
                }
            }
            if !models.isEmpty && !models.contains(where: \.supportsVision) {
                Text("No installed model reports vision support. To analyze images, install one locally, e.g.: ollama pull qwen2.5vl:7b")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Models that proxy to a cloud backend (e.g. “…-cloud”) are excluded. A localhost endpoint alone does not guarantee local inference — verify your server runs the selected model locally.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .onAppear {
            // Populate pickers from the server only when this tab is opened,
            // never periodically in the background.
            if config.enabled { testConnection(quiet: true) }
        }
    }

    private func testConnection(quiet: Bool = false) {
        guard let client = OllamaClient(endpoint: config.endpoint) else {
            statusMessage = AIError.nonLoopbackEndpoint.errorDescription
            return
        }
        testing = true
        if !quiet { statusMessage = nil }
        Task { @MainActor in
            defer { testing = false }
            do {
                let version = try await client.version()
                let all = try await client.listModels()
                let local = all.filter { !$0.isCloudBacked }
                let excluded = all.count - local.count
                models = local
                var msg = "Connected (Ollama \(version)). \(local.count) local model\(local.count == 1 ? "" : "s") found"
                if excluded > 0 { msg += "; \(excluded) cloud-backed model\(excluded == 1 ? "" : "s") excluded" }
                statusMessage = msg + "."
            } catch {
                if !quiet {
                    statusMessage = (error as? AIError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
