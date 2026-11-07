import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Bridge to Apple's on-device Foundation Models (Apple Intelligence).
///
/// Text-only: the public FoundationModels API takes no image input, so image
/// analysis always goes through the local server's vision model. Everything is
/// guarded both at compile time (`canImport`, for older SDKs/CI) and at run
/// time (macOS 26+ with Apple Intelligence enabled); the framework is
/// weak-linked so the app still launches on macOS 13.
enum AppleFMBridge {
    /// True when the framework is compiled in, the OS is new enough and the
    /// system model is ready to use.
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Human-readable availability state for the Settings UI.
    static var statusDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Apple Intelligence is available on this Mac."
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This Mac does not support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri."
                case .modelNotReady:
                    return "The Apple Intelligence model is still downloading or preparing. Try again later."
                @unknown default:
                    return "Apple Intelligence is currently unavailable."
                }
            @unknown default:
                return "Apple Intelligence is currently unavailable."
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }

    /// Streams a single-turn generation from the on-device model.
    static func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let task = Task {
                    do {
                        let session = LanguageModelSession(instructions: system)
                        var previous = ""
                        // Snapshots carry the cumulative content; emit deltas.
                        for try await snapshot in session.streamResponse(to: prompt) {
                            try Task.checkCancellation()
                            let full = snapshot.content
                            if full.count > previous.count {
                                continuation.yield(String(full.dropFirst(previous.count)))
                                previous = full
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: AIError.modelError(friendlyMessage(for: error)))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: AIError.notConfigured)
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func friendlyMessage(for error: Error) -> String {
        if let ge = error as? LanguageModelSession.GenerationError {
            switch ge {
            case .exceededContextWindowSize:
                return "The content is too long for the on-device Apple model. Select a smaller portion, or switch to a local server model in Settings → AI."
            case .guardrailViolation:
                return "The on-device Apple model declined this content (system guardrails)."
            case .unsupportedLanguageOrLocale:
                return "The on-device Apple model does not support this language."
            case .assetsUnavailable:
                return "The Apple Intelligence model assets are not available right now. Try again later."
            default:
                return "The on-device Apple model failed: \(ge.localizedDescription)"
            }
        }
        return "The on-device Apple model failed: \(error.localizedDescription)"
    }
    #endif
}
