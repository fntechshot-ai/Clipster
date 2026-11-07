import Foundation
import AppKit
import Vision
import ImageIO

/// Runs Apple Vision text recognition for image items, one image at a time,
/// off the main thread. All state transitions happen on the main thread.
final class OCRService: ObservableObject {
    /// Bump to invalidate previously cached results (backfill will redo them).
    static let engineVersion = 1

    /// Pixel cap: images beyond this are rejected instead of decoded.
    static let maxPixels = 60_000_000

    weak var manager: ClipboardManager?

    private var pendingIDs: [UUID] = []
    private var activeID: UUID?
    private var cancelledActive = false
    private let workQueue = DispatchQueue(label: "com.francisconeto.Clipster.ocr", qos: .utility)

    // Backfill progress (for the Settings UI).
    @Published private(set) var backfillRunning = false
    @Published private(set) var backfillTotal = 0
    @Published private(set) var backfillDone = 0

    enum RecognitionResult: Equatable {
        case text(String)
        case noText
        case failed(String) // sanitized error category, no content
    }

    // MARK: - Queue management (main thread)

    func enqueue(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeID != id, !pendingIDs.contains(id) else { return }
        pendingIDs.append(id)
        manager?.setOCRTransientStatus(id, .queued)
        pump()
    }

    /// Removes an item from the queue; a late result for it will be discarded.
    func cancel(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingIDs.removeAll { $0 == id }
        if activeID == id { cancelledActive = true }
    }

    var isBusy: Bool { activeID != nil || !pendingIDs.isEmpty }

    private func pump() {
        guard activeID == nil, !pendingIDs.isEmpty else { return }
        let id = pendingIDs.removeFirst()
        guard let manager, let data = manager.imageData(for: id) else {
            // Item vanished while queued.
            noteBackfillProgress()
            pump()
            return
        }
        activeID = id
        cancelledActive = false
        manager.setOCRTransientStatus(id, .processing)

        workQueue.async { [weak self] in
            let result = OCRService.recognize(pngData: data)
            DispatchQueue.main.async {
                self?.finish(id, result: result)
            }
        }
    }

    private func finish(_ id: UUID, result: RecognitionResult) {
        let wasCancelled = cancelledActive
        activeID = nil
        cancelledActive = false
        defer {
            noteBackfillProgress()
            pump()
        }
        // Discard late results for deleted/cancelled items; never resurrect records.
        guard !wasCancelled, let manager, manager.item(id) != nil else { return }
        switch result {
        case .text(let t): manager.applyOCRResult(id, text: t, errorCategory: nil)
        case .noText:      manager.applyOCRResult(id, text: nil, errorCategory: nil)
        case .failed(let category): manager.applyOCRResult(id, text: nil, errorCategory: category)
        }
    }

    // MARK: - Backfill (explicit, cancellable)

    func startBackfill() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let manager, !backfillRunning else { return }
        let ids = manager.imageItemsNeedingOCR(engine: Self.engineVersion)
        guard !ids.isEmpty else { return }
        backfillTotal = ids.count
        backfillDone = 0
        backfillRunning = true
        for id in ids { enqueue(id) }
    }

    func cancelBackfill() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard backfillRunning else { return }
        for id in pendingIDs {
            manager?.setOCRTransientStatus(id, nil)
        }
        pendingIDs.removeAll()
        backfillRunning = false
        backfillTotal = 0
        backfillDone = 0
    }

    private func noteBackfillProgress() {
        guard backfillRunning else { return }
        backfillDone += 1
        if backfillDone >= backfillTotal || !isBusy {
            backfillRunning = false
        }
    }

    // MARK: - Recognition (pure; safe to call from any queue)

    /// Preferred languages; intersected with what Vision supports at runtime.
    static let preferredLanguages = ["pt-PT", "pt-BR", "pt", "en-US", "en", "es-ES", "es"]

    static func recognize(pngData: Data) -> RecognitionResult {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(pngData as CFData, srcOptions) else {
            return .failed("unreadable image data")
        }
        // Bound decode cost before creating the bitmap.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w * h > maxPixels {
            return .failed("image too large")
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, srcOptions) else {
            return .failed("could not decode image")
        }
        var orientation = CGImagePropertyOrientation.up
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let o = CGImagePropertyOrientation(rawValue: raw) {
            orientation = o
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if let supported = try? request.supportedRecognitionLanguages() {
            let matched = preferredLanguages.filter { pref in
                supported.contains { $0 == pref || $0.hasPrefix(pref + "-") || pref.hasPrefix($0 + "-") }
            }
            if !matched.isEmpty {
                request.recognitionLanguages = matched
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failed("recognition error")
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .noText : .text(text)
    }
}
