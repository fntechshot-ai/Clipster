import Foundation
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

extension Notification.Name {
    static let clipsterPasteNow = Notification.Name("clipsterPasteNow")
    static let clipsterCaptureArea = Notification.Name("clipsterCaptureArea")
    static let clipsterCaptureText = Notification.Name("clipsterCaptureText")
    static let clipsterOpenSettings = Notification.Name("clipsterOpenSettings")
    static let clipsterPopoverOpened = Notification.Name("clipsterPopoverOpened")
    static let clipsterClosePopover = Notification.Name("clipsterClosePopover")
}

enum ClipType: String, Codable {
    case text = "TXT"
    case html = "HTML"
    case image = "IMG"
    case file = "FILE"
}

/// OCR lifecycle of an image item. `nil` on the item means "not processed".
/// Only terminal states (.done, .noText, .failed) are meaningful after a relaunch;
/// transient states found on disk are discarded at load time.
enum OCRStatus: String, Codable {
    case queued
    case processing
    case done
    case noText
    case failed
}

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var pinned: Bool
    let date: Date
    let type: ClipType
    var text: String?
    var html: String?
    var imagePNG: Data?
    var files: [String]?

    // OCR fields — all optional so pre-OCR history files keep loading.
    var ocrText: String?
    var ocrStatus: OCRStatus?
    var ocrDate: Date?
    var ocrEngine: Int?
    var ocrError: String?

    // Source application the content was copied from. Both nil means unknown
    // (including all items recorded before provenance existed — their origins
    // are never invented). Clipster-generated items (captures, OCR copies,
    // AI results) carry Clipster's own bundle id.
    var sourceAppName: String? = nil
    var sourceBundleID: String? = nil

    // Equality is content-based (used for de-duplication), so OCR state is excluded.
    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.type == rhs.type &&
        lhs.text == rhs.text &&
        lhs.html == rhs.html &&
        lhs.imagePNG == rhs.imagePNG &&
        lhs.files == rhs.files
    }
}

/// List filter applied by the chip shelf, combined with search and source filter.
enum ClipTypeFilter: String, CaseIterable {
    case all = "All"
    case pinned = "Pinned"
    case text = "Text"
    case images = "Images"
    case files = "Files"

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.pinned
        case .text: return item.type == .text || item.type == .html
        case .images: return item.type == .image
        case .files: return item.type == .file
        }
    }
}

final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var typeFilter: ClipTypeFilter = .all
    /// Source-app name to filter by; nil shows every source.
    @Published var sourceFilter: String?

    /// When set, ContentView shows the detail panel for this item.
    @Published var detailItemID: UUID?
    /// AI action the detail panel should start automatically (set from context menus).
    @Published var pendingAIAction: AIAction?

    let ocr = OCRService()

    private let defaults = UserDefaults.standard

    @Published var isCapturing: Bool = true {
        didSet { defaults.set(isCapturing, forKey: "isCapturing") }
    }
    @Published var maxItems: Int = 200 {
        didSet { defaults.set(maxItems, forKey: "maxItems") }
    }
    /// When true, items marked as concealed (e.g. passwords from password managers)
    /// are NOT captured. Off by default so copying passwords keeps working.
    @Published var ignorePasswords: Bool = false {
        didSet { defaults.set(ignorePasswords, forKey: "ignorePasswords") }
    }
    /// Automatically run OCR on newly captured images.
    @Published var autoOCR: Bool = true {
        didSet { defaults.set(autoOCR, forKey: "autoOCR") }
    }

    /// Skip images larger than this so history.json doesn't balloon.
    private let maxImageBytes = 8 * 1024 * 1024

    /// Pasteboard type used by password managers to mark sensitive content.
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Explicit source metadata some apps attach (nspasteboard.org convention).
    private let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    /// Marker macOS puts on Universal Clipboard content from another device.
    private let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    static let selfBundleID = Bundle.main.bundleIdentifier ?? "com.francisconeto.Clipster"
    static let selfSourceName = "Clipster"

    /// Returns the app active right now; injectable so tests can control it.
    /// The default reads NSWorkspace at change-detection time (best effort).
    var frontmostAppProvider: () -> (name: String?, bundleID: String?) = {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }

    /// Origin recorded for the next self-induced pasteboard change, so items
    /// re-copied through Clipster keep their original source and Clipster's own
    /// output is tracked as Clipster-generated. Matched by change count and
    /// discarded if anything else touched the pasteboard in between.
    private var pendingAttribution: (changeCount: Int, name: String?, bundleID: String?)?

    private let pb: NSPasteboard
    private var lastChangeCount: Int = 0
    private var timer: Timer?

    private let storeURL: URL

    /// `pasteboard` and `storeURL` are injectable for tests; defaults are the real ones.
    /// A development build can also be pointed at an isolated store with
    /// CLIPSTER_STORE_DIR, so it never touches the real history file.
    init(pasteboard: NSPasteboard = .general, storeURL: URL? = nil) {
        self.pb = pasteboard
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let dir: URL
            if let override = ProcessInfo.processInfo.environment["CLIPSTER_STORE_DIR"], !override.isEmpty {
                dir = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Clipster", isDirectory: true)
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("history.json")
        }
        ocr.manager = self
    }

    func start() {
        loadSettings()
        load()
        lastChangeCount = pb.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func loadSettings() {
        if defaults.object(forKey: "isCapturing") != nil { isCapturing = defaults.bool(forKey: "isCapturing") }
        if defaults.object(forKey: "maxItems") != nil { maxItems = defaults.integer(forKey: "maxItems") }
        if defaults.object(forKey: "ignorePasswords") != nil { ignorePasswords = defaults.bool(forKey: "ignorePasswords") }
        if defaults.object(forKey: "autoOCR") != nil { autoOCR = defaults.bool(forKey: "autoOCR") }
    }

    func tick() {
        guard isCapturing else { return }
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        captureCurrent()
    }

    private func captureCurrent() {
        // Resolve provenance for this pasteboard generation up front, so the
        // pending self-attribution is consumed even when nothing is stored.
        let source = attributionForCurrentChange()

        // Respect password managers that mark their clipboard entries as concealed.
        if ignorePasswords, let types = pb.types, types.contains(concealedType) {
            return
        }

        if let s = pb.string(forType: .string), !s.isEmpty {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .text, text: s, html: nil, imagePNG: nil, files: nil,
                         sourceAppName: source.name, sourceBundleID: source.bundleID))
            return
        }
        if let html = pb.string(forType: .html) {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .html, text: htmlToPlainText(html), html: html, imagePNG: nil, files: nil,
                         sourceAppName: source.name, sourceBundleID: source.bundleID))
            return
        }
        if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff),
           let png = nsImageToPNG(img), png.count <= maxImageBytes {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .image, text: nil, html: nil, imagePNG: png, files: nil,
                         sourceAppName: source.name, sourceBundleID: source.bundleID))
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .file, text: nil, html: nil, imagePNG: nil, files: urls.map { $0.absoluteString },
                         sourceAppName: source.name, sourceBundleID: source.bundleID))
            return
        }
    }

    // MARK: - Source attribution

    /// Decides where the current pasteboard content came from. Both fields nil
    /// means "Unknown source" — preferred over guessing when attribution is
    /// unreliable (rapid app switching, background writes, Clipster frontmost).
    func attributionForCurrentChange() -> (name: String?, bundleID: String?) {
        // 1. A write Clipster itself just made, carrying its recorded origin.
        if let pending = pendingAttribution {
            pendingAttribution = nil
            if pending.changeCount == pb.changeCount {
                return (pending.name, pending.bundleID)
            }
            // Something else wrote in between — fall through and re-resolve.
        }
        // 2. Explicit source metadata provided by the copying app.
        if let bundleID = pb.string(forType: sourceType)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleID.isEmpty {
            return (Self.appName(forBundleID: bundleID) ?? bundleID, bundleID)
        }
        // 3. Universal Clipboard content copied on another device.
        if pb.types?.contains(remoteClipboardType) == true {
            return ("Another device", nil)
        }
        // 4. Best effort: the app active when the change was detected.
        let front = frontmostAppProvider()
        if let bid = front.bundleID, bid == Self.selfBundleID {
            // A write landed while Clipster was frontmost that we didn't make
            // ourselves — attribution would be a guess, so record none.
            return (nil, nil)
        }
        return (front.name, front.bundleID)
    }

    /// Resolves a bundle identifier to a display name using local metadata only.
    static func appName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        return name ?? url.deletingPathExtension().lastPathComponent
    }

    /// Distinct source-app names present in history, for the filter menu.
    var availableSources: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for item in items {
            if let n = item.sourceAppName, seen.insert(n).inserted { names.append(n) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Inserts an item at the top (de-duplicating against the current top item)
    /// and returns the id of the effective item. Must be called on the main thread.
    @discardableResult
    func append(_ item: ClipItem) -> UUID {
        if let first = items.first, first == item { return first.id }
        items.insert(item, at: 0)
        if items.count > maxItems {
            let removed = items.suffix(items.count - maxItems)
            for r in removed { ocr.cancel(r.id) }
            items.removeLast(items.count - maxItems)
        }
        save()
        // Capture Text items arrive with OCR already attached — don't redo them.
        if item.type == .image && autoOCR && item.ocrStatus == nil {
            ocr.enqueue(item.id)
        }
        return item.id
    }

    // MARK: - Lookup

    func item(_ id: UUID) -> ClipItem? {
        items.first(where: { $0.id == id })
    }

    func imageData(for id: UUID) -> Data? {
        item(id)?.imagePNG
    }

    /// Image items that still need OCR with the current engine (used by backfill).
    func imageItemsNeedingOCR(engine: Int) -> [UUID] {
        items.filter { item in
            guard item.type == .image, item.imagePNG != nil else { return false }
            switch item.ocrStatus {
            case .done, .noText:
                return (item.ocrEngine ?? 0) < engine
            case .failed, .queued, .processing, nil:
                // failed items are retried explicitly by backfill; transient states requeue
                return item.ocrStatus != .queued && item.ocrStatus != .processing
            }
        }.map { $0.id }
    }

    // MARK: - OCR state updates (called by OCRService on the main thread)

    /// Transient status update (queued/processing). Not persisted — a relaunch resets it.
    func setOCRTransientStatus(_ id: UUID, _ status: OCRStatus?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].ocrStatus = status
    }

    /// Terminal OCR result. Persisted.
    func applyOCRResult(_ id: UUID, text: String?, errorCategory: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let errorCategory {
            items[idx].ocrStatus = .failed
            items[idx].ocrError = errorCategory
            items[idx].ocrText = nil
        } else if let text, !text.isEmpty {
            items[idx].ocrStatus = .done
            items[idx].ocrText = text
            items[idx].ocrError = nil
        } else {
            items[idx].ocrStatus = .noText
            items[idx].ocrText = nil
            items[idx].ocrError = nil
        }
        items[idx].ocrDate = Date()
        items[idx].ocrEngine = OCRService.engineVersion
        save()
    }

    // MARK: - Search

    var orderedItems: [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            guard typeFilter.matches(item) else { return false }
            if let source = sourceFilter, item.sourceAppName != source { return false }
            if !trimmed.isEmpty, !Self.matches(item, query: trimmed) { return false }
            return true
        }
        return filtered.sorted { (a, b) -> Bool in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.date > b.date
        }
    }

    /// Case- and diacritic-insensitive containment check.
    static func textMatches(_ haystack: String?, _ query: String) -> Bool {
        guard let haystack, !haystack.isEmpty else { return false }
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func matches(_ item: ClipItem, query: String) -> Bool {
        if textMatches(item.text, query) { return true }
        if textMatches(item.html, query) { return true }
        if let f = item.files?.joined(separator: " "), textMatches(f, query) { return true }
        if textMatches(item.ocrText, query) { return true }
        if textMatches(item.sourceAppName, query) { return true }
        return false
    }

    /// Short context snippet around the first match of `query` in `text`, for search results.
    static func snippet(of text: String, matching query: String, context: Int = 24) -> String? {
        guard let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(r.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { s = "…" + s }
        if end < text.endIndex { s += "…" }
        return s
    }

    // MARK: - Pasteboard writes initiated by Clipster

    /// Marks the current pasteboard generation as self-induced so the watcher
    /// does not re-capture content Clipster itself just wrote.
    private func suppressWatcherForCurrentChange() {
        lastChangeCount = pb.changeCount
    }

    /// Puts captured image data on the clipboard and (unless history is paused)
    /// stores it once in history, attributed to the app that was on screen when
    /// the capture was invoked (best effort; unknown when undeterminable).
    /// Returns the history item id, or nil when paused.
    @discardableResult
    func storeCapturedImage(_ png: Data,
                            sourceAppName: String? = nil, sourceBundleID: String? = nil) -> UUID? {
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        suppressWatcherForCurrentChange()

        guard isCapturing else { return nil }
        let item = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                            text: nil, html: nil, imagePNG: png, files: nil,
                            sourceAppName: sourceAppName, sourceBundleID: sourceBundleID)
        return append(item)
    }

    /// Puts recognized text on the clipboard and (unless history is paused) stores
    /// the source image once in history with its OCR text already attached,
    /// attributed like storeCapturedImage.
    @discardableResult
    func storeCapturedText(_ text: String, sourcePNG: Data,
                           sourceAppName: String? = nil, sourceBundleID: String? = nil) -> UUID? {
        pb.clearContents()
        pb.setString(text, forType: .string)
        suppressWatcherForCurrentChange()

        guard isCapturing else { return nil }
        var item = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                            text: nil, html: nil, imagePNG: sourcePNG, files: nil,
                            sourceAppName: sourceAppName, sourceBundleID: sourceBundleID)
        item.ocrText = text
        item.ocrStatus = .done
        item.ocrDate = Date()
        item.ocrEngine = OCRService.engineVersion
        return append(item)
    }

    /// Copies a string without pasting (used by "Copy Text" / "Copy Result").
    /// The new clipboard content is captured into history like any user copy,
    /// attributed to Clipster itself (it is Clipster-generated output).
    func copyString(_ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        pendingAttribution = (pb.changeCount, Self.selfSourceName, Self.selfBundleID)
    }

    func paste(_ item: ClipItem, plainText: Bool) {
        pb.clearContents()

        switch item.type {
        case .image:
            if let data = item.imagePNG, let img = NSImage(data: data) {
                pb.writeObjects([img])
            }

        case .file:
            if let files = item.files {
                let urls = files.compactMap { URL(string: $0) }
                pb.writeObjects(urls as [NSPasteboardWriting])
            }

        case .text:
            let s = item.text ?? ""
            pb.setString(s, forType: .string)

        case .html:
            if plainText {
                let s = htmlToPlainText(item.html ?? item.text ?? "")
                pb.setString(s, forType: .string)
            } else {
                if let html = item.html {
                    pb.setString(html, forType: .html)
                } else {
                    pb.setString(item.text ?? "", forType: .string)
                }
            }
        }

        // Re-copying through Clipster must preserve the item's original source;
        // the watcher will apply it when it records the new top item.
        pendingAttribution = (pb.changeCount, item.sourceAppName, item.sourceBundleID)

        // Ask the app to close the popover, refocus previous app, then press ⌘V.
        // Only do this for text/html, since other types (images/files) may not be pasteable via ⌘V.
        if item.type == .text || item.type == .html {
            NotificationCenter.default.post(name: .clipsterPasteNow, object: nil)
        }
    }

    func togglePin(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].pinned.toggle()
            save()
            objectWillChange.send()
        }
    }

    func delete(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            ocr.cancel(item.id)
            if detailItemID == item.id { detailItemID = nil }
            items.remove(at: idx)
            save()
            objectWillChange.send()
        }
    }

    func clearUnpinned() {
        for it in items where !it.pinned { ocr.cancel(it.id) }
        if let d = detailItemID, let it = item(d), !it.pinned { detailItemID = nil }
        items.removeAll(where: { !$0.pinned })
        save()
        objectWillChange.send()
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("Save failed: \(error)")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        // Transient OCR states must not survive a relaunch as stuck work.
        items = arr.map { item in
            var item = item
            if item.ocrStatus == .queued || item.ocrStatus == .processing {
                item.ocrStatus = nil
            }
            return item
        }
    }

    private func nsImageToPNG(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let att = try? NSAttributedString(data: data,
                                             options: [.documentType: NSAttributedString.DocumentType.html,
                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                             documentAttributes: nil) {
            return att.string
        }
        return html
    }
}
