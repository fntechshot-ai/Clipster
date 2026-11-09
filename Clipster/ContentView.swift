import SwiftUI
import AppKit

/// Compact relative timestamp ("now", "5m", "3h", "2d") in the spirit of the
/// design's "12m ago", without the verbosity of the system relative style.
func compactAge(of date: Date, reference: Date = Date()) -> String {
    let s = max(0, reference.timeIntervalSince(date))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86_400: return "\(Int(s / 3600))h"
    default: return "\(Int(s / 86_400))d"
    }
}

/// Resolves and caches source-app icons locally (no network, metadata only).
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if bundleID == ClipboardManager.selfBundleID { return NSApp.applicationIconImage }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// Small "app icon + name · time" line used in rows and the detail header.
struct SourceBadge: View {
    let name: String?
    let bundleID: String?
    var showUnknown = false

    var body: some View {
        if name != nil || showUnknown {
            HStack(spacing: 4) {
                if let icon = AppIconCache.icon(forBundleID: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(name ?? "Unknown source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Source: \(name ?? "unknown")")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var manager: ClipboardManager
    @ObservedObject var aiConfig = AIConfig.shared
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let id = manager.detailItemID, let item = manager.item(id) {
                DetailView(item: item)
                    .environmentObject(manager)
            } else {
                listView
            }
        }
    }

    // MARK: - History list

    private var listView: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            chipShelf
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(Array(manager.orderedItems.enumerated()), id: \.element.id) { index, item in
                        ClipRow(item: item, shortcutIndex: index < 4 ? index + 1 : nil)
                            .environmentObject(manager)
                            .tag(item.id)
                            .id(item.id)
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedID) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 400, minHeight: 520)
        .background(keyboardShortcuts)
        .onAppear {
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipsterPopoverOpened)) { _ in
            selectedID = nil
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search clips, apps, or text in images", text: $manager.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search clipboard history, including app names and text recognized in images")
                if !manager.query.isEmpty {
                    Button {
                        manager.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

            sourceFilterMenu

            Button {
                NotificationCenter.default.post(name: .clipsterCaptureArea, object: nil)
            } label: {
                Image(systemName: "camera.viewfinder")
            }
            .help("Capture Area — copy a screen selection as an image")
            .accessibilityLabel("Capture screen area as image")

            Button {
                NotificationCenter.default.post(name: .clipsterCaptureText, object: nil)
            } label: {
                Image(systemName: "text.viewfinder")
            }
            .help("Capture Text — copy the text in a screen selection")
            .accessibilityLabel("Capture text from screen area")

            Button {
                NotificationCenter.default.post(name: .clipsterOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Open Settings")
        }
    }

    private var sourceFilterMenu: some View {
        Menu {
            Picker("Source", selection: $manager.sourceFilter) {
                Text("All Sources").tag(String?.none)
                ForEach(manager.availableSources, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: manager.sourceFilter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(manager.sourceFilter.map { "Filtering by \($0)" } ?? "Filter by source app")
        .accessibilityLabel(manager.sourceFilter.map { "Source filter active: \($0)" } ?? "Filter by source app")
    }

    private var chipShelf: some View {
        HStack(spacing: 6) {
            ForEach(ClipTypeFilter.allCases, id: \.self) { filter in
                FilterChip(title: filter.rawValue,
                           isOn: manager.typeFilter == filter) {
                    manager.typeFilter = filter
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                Text("↩ Paste")
                Text("⌥↩ Plain")
                Text("⌘⌫ Delete")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            Spacer()
            Button {
                manager.clearUnpinned()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Remove all unpinned items")
            .accessibilityLabel("Clear unpinned items")
            Text("\(manager.orderedItems.count) item\(manager.orderedItems.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Keyboard handling

    /// Hidden buttons give the popover full keyboard control even while the
    /// search field has focus: ↑/↓ move the selection, ↩ pastes the selected
    /// (or first) item, ⌥↩ pastes as plain text, ⌘⌫ deletes, ⌘1–⌘4 paste the
    /// top items directly, Esc clears the search and then closes the popover.
    private var keyboardShortcuts: some View {
        Group {
            ShortcutButton(.return, []) { pasteSelection(plainText: false) }
            ShortcutButton(.return, .option) { pasteSelection(plainText: true) }
            ShortcutButton(.delete, .command) { deleteSelection() }
            ShortcutButton(.upArrow, []) { moveSelection(-1) }
            ShortcutButton(.downArrow, []) { moveSelection(1) }
            ShortcutButton("f", .command) { searchFocused = true }
            ShortcutButton(.escape, []) {
                if !manager.query.isEmpty {
                    manager.query = ""
                } else {
                    NotificationCenter.default.post(name: .clipsterClosePopover, object: nil)
                }
            }
            ForEach(Array(manager.orderedItems.prefix(4).enumerated()), id: \.element.id) { index, item in
                ShortcutButton(KeyEquivalent(Character("\(index + 1)")), .command) {
                    manager.paste(item, plainText: false)
                }
            }
        }
    }

    private var selectionOrFirst: ClipItem? {
        if let id = selectedID, let item = manager.item(id) { return item }
        return manager.orderedItems.first
    }

    private func pasteSelection(plainText: Bool) {
        guard let item = selectionOrFirst else { return }
        manager.paste(item, plainText: plainText)
    }

    private func deleteSelection() {
        guard let id = selectedID, let item = manager.item(id) else { return }
        let ordered = manager.orderedItems
        let next = ordered.firstIndex(where: { $0.id == id })
            .flatMap { idx in ordered.indices.contains(idx + 1) ? ordered[idx + 1].id : nil }
        manager.delete(item)
        selectedID = next
    }

    private func moveSelection(_ delta: Int) {
        let ordered = manager.orderedItems
        guard !ordered.isEmpty else { return }
        guard let current = selectedID, let idx = ordered.firstIndex(where: { $0.id == current }) else {
            selectedID = delta > 0 ? ordered.first?.id : ordered.last?.id
            return
        }
        let next = min(max(idx + delta, 0), ordered.count - 1)
        selectedID = ordered[next].id
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("Paste") { manager.paste(item, plainText: false) }
        if item.type == .text || item.type == .html {
            Button("Paste as Plain Text") { manager.paste(item, plainText: true) }
        }
        Button(item.type == .image ? "Copy Image" : "Copy") { manager.copyOnly(item) }
        Divider()
        if item.type == .image {
            switch item.ocrStatus {
            case .done:
                Button("View Text") { manager.detailItemID = item.id }
                Button("Copy Text") { manager.copyString(item.ocrText ?? "") }
            case .queued, .processing:
                Button("View Text") { manager.detailItemID = item.id }
            default:
                Button("Extract Text") {
                    manager.ocr.enqueue(item.id)
                    manager.detailItemID = item.id
                }
            }
        }
        if (item.type == .text || item.type == .html), aiConfig.isReadyForText {
            Menu("AI Actions") {
                Menu("Translate") {
                    ForEach(AIAction.translateTargets, id: \.self) { target in
                        Button(target) { startAI(.translate(target: target), item: item) }
                    }
                }
                Button("Summarize") { startAI(.summarize, item: item) }
                Menu("Rewrite") {
                    ForEach(AIAction.RewritePreset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) { startAI(.rewrite(preset), item: item) }
                    }
                }
                Button("Explain") { startAI(.explain, item: item) }
            }
        }
        Button("Details…") { manager.detailItemID = item.id }
        if let source = item.sourceAppName {
            Button("Show Only Items from \(source)") { manager.sourceFilter = source }
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { manager.togglePin(item) }
        Button("Delete", role: .destructive) { manager.delete(item) }
    }

    private func startAI(_ action: AIAction, item: ClipItem) {
        manager.pendingAIAction = action
        manager.detailItemID = item.id
    }
}

/// Invisible button that exists only to register a keyboard shortcut.
private struct ShortcutButton: View {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers, action: @escaping () -> Void) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isOn ? .semibold : .regular)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .overlay(
                    Capsule().stroke(isOn ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.35),
                                     lineWidth: 0.5)
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) filter")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct ClipRow: View {
    @EnvironmentObject var manager: ClipboardManager
    let item: ClipItem
    var shortcutIndex: Int?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 36, height: 36)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    SourceBadge(name: item.sourceAppName, bundleID: item.sourceBundleID)
                    if item.sourceAppName != nil {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(compactAge(of: item.date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("copied \(compactAge(of: item.date)) ago")
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Pinned")
                            .accessibilityLabel("Pinned")
                    }
                    if item.type == .image { ocrIndicator }
                    Spacer(minLength: 0)
                }
                Text(previewText)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 4)

            if hovering {
                Button("Paste") {
                    manager.paste(item, plainText: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if let n = shortcutIndex {
                Text("⌘\(n)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Command \(n) pastes this item")
            }

            Menu {
                Button("Paste") { manager.paste(item, plainText: false) }
                if item.type == .text || item.type == .html {
                    Button("Paste as Plain Text") { manager.paste(item, plainText: true) }
                }
                Button(item.type == .image ? "Copy Image" : "Copy") { manager.copyOnly(item) }
                Divider()
                Button("Details…") { manager.detailItemID = item.id }
                Button(item.pinned ? "Unpin" : "Pin") { manager.togglePin(item) }
                Button("Delete", role: .destructive) { manager.delete(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .accessibilityLabel("More actions")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { manager.paste(item, plainText: false) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var rowAccessibilityLabel: String {
        var parts: [String] = []
        parts.append(previewText)
        if let s = item.sourceAppName { parts.append("from \(s)") }
        if item.pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    /// Small, non-color-only OCR state indicator for image rows.
    @ViewBuilder
    private var ocrIndicator: some View {
        switch item.ocrStatus {
        case .queued, .processing:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Text recognition in progress")
                .accessibilityLabel("Text recognition in progress")
        case .done:
            Image(systemName: "text.viewfinder")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Text recognized — searchable")
                .accessibilityLabel("Text recognized")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Text recognition failed")
                .accessibilityLabel("Text recognition failed")
        case .noText, nil:
            EmptyView()
        }
    }

    private var previewText: String {
        switch item.type {
        case .image:
            let q = manager.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty, let ocr = item.ocrText,
               let snip = ClipboardManager.snippet(of: ocr, matching: q) {
                return snip
            }
            if let ocr = item.ocrText, !ocr.isEmpty {
                return ocr.split(separator: "\n").first.map(String.init) ?? ocr
            }
            return "Image"
        case .file:
            return item.files?.map { URL(string: $0)?.lastPathComponent ?? $0 }.joined(separator: ", ") ?? "File"
        case .html:
            return item.text ?? "HTML"
        case .text:
            return item.text ?? "Text"
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.type {
        case .image:
            if let data = item.imagePNG, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipped()
            } else {
                ZStack { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        case .file:
            ZStack { Image(systemName: "doc").foregroundStyle(.secondary) }
        case .html, .text:
            ZStack { Image(systemName: "doc.text").foregroundStyle(.secondary) }
        }
    }
}

struct TypeBadge: View {
    let type: ClipType
    var body: some View {
        Text(type.rawValue)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}
