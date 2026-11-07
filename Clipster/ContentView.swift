import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var manager: ClipboardManager
    @ObservedObject var aiConfig = AIConfig.shared

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

    private var listView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search history…", text: $manager.query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .accessibilityLabel("Search clipboard history, including text recognized in images")
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
                    manager.clearUnpinned()
                } label: {
                    Label("Clear unpinned", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Remove all unpinned items")
                .accessibilityLabel("Clear unpinned items")
                Button {
                    NotificationCenter.default.post(name: .clipsterOpenSettings, object: nil)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Open Settings")
            }
            .padding(.horizontal)

            List {
                ForEach(manager.orderedItems) { item in
                    ClipRow(item: item)
                        .environmentObject(manager)
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .listStyle(.plain)
            .frame(minWidth: 420, minHeight: 500)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button(item.type == .image ? "Copy Image" : "Paste") { manager.paste(item, plainText: false) }
        if item.type == .text || item.type == .html {
            Button("Paste as Plain Text") { manager.paste(item, plainText: true) }
        }
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
            if aiConfig.enabled {
                Button("Analyze Image") { manager.detailItemID = item.id }
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
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { manager.togglePin(item) }
        Button("Delete", role: .destructive) { manager.delete(item) }
    }

    private func startAI(_ action: AIAction, item: ClipItem) {
        manager.pendingAIAction = action
        manager.detailItemID = item.id
    }
}

struct ClipRow: View {
    @EnvironmentObject var manager: ClipboardManager
    let item: ClipItem

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 40, height: 40)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TypeBadge(type: item.type)
                    if item.pinned { Image(systemName: "pin.fill").help("Pinned") }
                    if item.type == .image { ocrIndicator }
                    Text(item.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(previewText)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button {
                manager.detailItemID = item.id
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Details")
            .accessibilityLabel("Show details")
            Menu {
                Button(item.type == .image ? "Copy Image" : "Paste") { manager.paste(item, plainText: false) }
                if item.type == .text || item.type == .html {
                    Button("Paste as Plain Text") { manager.paste(item, plainText: true) }
                }
                Divider()
                Button("Details…") { manager.detailItemID = item.id }
                Button(item.pinned ? "Unpin" : "Pin") { manager.togglePin(item) }
                Button("Delete", role: .destructive) { manager.delete(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
            Button(item.type == .image ? "Copy" : "Paste") { manager.paste(item, plainText: false) }
                .buttonStyle(.borderedProminent)
        }
        .contentShape(Rectangle())
        .onTapGesture { manager.paste(item, plainText: false) }
    }

    /// Small, non-color-only OCR state indicator for image rows.
    @ViewBuilder
    private var ocrIndicator: some View {
        switch item.ocrStatus {
        case .queued, .processing:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Text recognition in progress")
                .accessibilityLabel("Text recognition in progress")
        case .done:
            Image(systemName: "text.viewfinder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Text recognized — searchable")
                .accessibilityLabel("Text recognized")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
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
                let firstLine = ocr.split(separator: "\n").first.map(String.init) ?? ocr
                return "🖼 " + firstLine
            }
            return "(Image)"
        case .file:
            return item.files?.map { URL(string: $0)?.lastPathComponent ?? $0 }.joined(separator: ", ") ?? "(File)"
        case .html:
            return item.text ?? "(HTML)"
        case .text:
            return item.text ?? "(Text)"
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
            } else {
                ZStack { Image(systemName: "photo") }
            }
        case .file:
            ZStack { Image(systemName: "doc"); Text("FILE").font(.caption2).padding(2) }
        case .html, .text:
            ZStack { Image(systemName: "doc.text"); Text(item.type.rawValue).font(.caption2).padding(2) }
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
