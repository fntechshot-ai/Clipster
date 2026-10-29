import Foundation
import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

enum ClipType: String, Codable {
    case text = "TXT"
    case html = "HTML"
    case image = "IMG"
    case file = "FILE"
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

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.type == rhs.type &&
        lhs.text == rhs.text &&
        lhs.html == rhs.html &&
        lhs.imagePNG == rhs.imagePNG &&
        lhs.files == rhs.files
    }
}

final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = ""

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

    /// Skip images larger than this so history.json doesn't balloon.
    private let maxImageBytes = 8 * 1024 * 1024

    /// Pasteboard type used by password managers to mark sensitive content.
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pb = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var timer: Timer?

    private lazy var storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = dir.appendingPathComponent("Clipster", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("history.json")
    }()

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
    }

    private func tick() {
        guard isCapturing else { return }
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        captureCurrent()
    }

    private func captureCurrent() {
        // Respect password managers that mark their clipboard entries as concealed.
        if ignorePasswords, let types = pb.types, types.contains(concealedType) {
            return
        }

        if let s = pb.string(forType: .string), !s.isEmpty {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .text, text: s, html: nil, imagePNG: nil, files: nil))
            return
        }
        if let html = pb.string(forType: .html) {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .html, text: htmlToPlainText(html), html: html, imagePNG: nil, files: nil))
            return
        }
        if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff),
           let png = nsImageToPNG(img), png.count <= maxImageBytes {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .image, text: nil, html: nil, imagePNG: png, files: nil))
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            append(.init(id: UUID(), pinned: false, date: Date(), type: .file, text: nil, html: nil, imagePNG: nil, files: urls.map { $0.absoluteString }))
            return
        }
    }

    private func append(_ item: ClipItem) {
        DispatchQueue.main.async {
            if let first = self.items.first, first == item { return }
            self.items.insert(item, at: 0)
            if self.items.count > self.maxItems {
                self.items.removeLast(self.items.count - self.maxItems)
            }
            self.save()
        }
    }

    var orderedItems: [ClipItem] {
        let base = items
        let filtered: [ClipItem]
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = base
        } else {
            filtered = base.filter { item in
                if let t = item.text, t.localizedCaseInsensitiveContains(query) { return true }
                if let h = item.html, h.localizedCaseInsensitiveContains(query) { return true }
                if let f = item.files?.joined(separator: " "), f.localizedCaseInsensitiveContains(query) { return true }
                return false
            }
        }
        return filtered.sorted { (a, b) -> Bool in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.date > b.date
        }
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
            items.remove(at: idx)
            save()
            objectWillChange.send()
        }
    }

    func clearUnpinned() {
        items.removeAll(where: { !$0.pinned })
        save()
        objectWillChange.send()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("Save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let arr = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = arr
    }

    private func nsImageToPNG(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        if let att = try? NSAttributedString(data: data,
                                             options: [.documentType: NSAttributedString.DocumentType.html,
                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                             documentAttributes: nil) {
            return att.string
        }
        return html
    }
    private func simulatePasteKeystroke() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
