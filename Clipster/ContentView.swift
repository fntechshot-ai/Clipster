import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var manager: ClipboardManager

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search history…", text: $manager.query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button {
                    manager.clearUnpinned()
                } label: {
                    Label("Clear unpinned", systemImage: "trash")
                }
                .help("Remove all unpinned items")
            }
            .padding(.horizontal)

            List {
                ForEach(manager.orderedItems) { item in
                    ClipRow(item: item)
                        .environmentObject(manager)
                        .contextMenu {
                            Button("Paste") { manager.paste(item, plainText: false) }
                            if item.type == .text || item.type == .html {
                                Button("Paste as Plain Text") { manager.paste(item, plainText: true) }
                            }
                            Divider()
                            Button(item.pinned ? "Unpin" : "Pin") { manager.togglePin(item) }
                            Button("Delete", role: .destructive) { manager.delete(item) }
                        }
                }
            }
            .listStyle(.plain)
            .frame(minWidth: 420, minHeight: 500)
        }
        .padding(.vertical, 8)
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
            Menu {
                Button("Paste") { manager.paste(item, plainText: false) }
                if item.type == .text || item.type == .html {
                    Button("Paste as Plain Text") { manager.paste(item, plainText: true) }
                }
                Divider()
                Button(item.pinned ? "Unpin" : "Pin") { manager.togglePin(item) }
                Button("Delete", role: .destructive) { manager.delete(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Button("Paste") { manager.paste(item, plainText: false) }
                .buttonStyle(.borderedProminent)
        }
        .contentShape(Rectangle())
        .onTapGesture { manager.paste(item, plainText: false) }
    }

    private var previewText: String {
        switch item.type {
        case .image: return "(Image)"
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
