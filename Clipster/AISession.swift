import Foundation

/// Persisted AI configuration (UserDefaults-backed). Text actions run on
/// Apple's on-device model (Apple Intelligence) only — there is no server
/// backend, no endpoint and nothing to install.
final class AIConfig: ObservableObject {
    static let shared = AIConfig()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "aiEnabled") }
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "aiEnabled")
    }

    /// Why text actions can't run right now, or nil when they can.
    var textSetupHint: String? {
        if !enabled { return "AI actions are disabled. Enable them in Settings → AI." }
        return AppleFMBridge.isSupported ? nil : AppleFMBridge.statusDescription
    }

    var isReadyForText: Bool { textSetupHint == nil }
}

/// Drives one generation for the detail panel, streaming from the on-device
/// Apple model. One session per panel; output is in-memory until the user
/// explicitly copies or saves it.
@MainActor
final class AISession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var running = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var finished = false

    private var task: Task<Void, Never>?
    private var lastRun: (() -> Void)?
    /// Guards against a cancelled run's teardown clobbering a newer run's state.
    private var generation = 0

    func run(action: AIAction, content: String, config: AIConfig) {
        lastRun = { [weak self] in self?.run(action: action, content: content, config: config) }
        cancel()
        errorMessage = nil
        output = ""
        finished = false

        guard config.isReadyForText else {
            errorMessage = config.textSetupHint ?? AIError.notConfigured.errorDescription
            return
        }
        guard content.count <= AILimits.maxInputCharacters else {
            errorMessage = AIError.inputTooLong(content.count).errorDescription
            return
        }

        running = true
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            do {
                let stream = AppleFMBridge.stream(system: action.systemPrompt, prompt: content)
                for try await chunk in stream {
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    self.output += chunk
                }
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.running = false
                self.finished = true
            } catch is CancellationError {
                guard let self, self.generation == gen else { return }
                self.running = false
            } catch {
                guard let self, self.generation == gen else { return }
                self.running = false
                self.errorMessage = (error as? AIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    func retry() {
        lastRun?()
    }

    func resetAll() {
        cancel()
        output = ""
        errorMessage = nil
        finished = false
    }
}
