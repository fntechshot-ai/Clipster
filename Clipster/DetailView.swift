import SwiftUI
import AppKit

/// Focused detail/result panel for one history item: image preview, recognized
/// text, and on-demand local AI actions. Shown inside the popover in place of
/// the list; the Back button returns to history.
struct DetailView: View {
    @EnvironmentObject var manager: ClipboardManager
    @ObservedObject var config = AIConfig.shared
    @StateObject private var textSession = AISession()
    @StateObject private var imageSession = AISession()

    let item: ClipItem

    @State private var customInstruction = ""
    @State private var customTarget = ""
    @State private var analysisPrompt = ""
    @State private var followUp = ""

    private var sourceText: String? {
        switch item.type {
        case .text, .html: return item.text
        case .image: return item.ocrText
        case .file: return nil
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if item.type == .image { imagePreview; ocrSection }
                    if item.type == .text || item.type == .html { originalTextSection }
                    if sourceText != nil { aiTextSection }
                    if item.type == .image { analyzeImageSection }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 8)
        .onAppear(perform: runPendingActionIfAny)
        .onDisappear {
            textSession.cancel()
            imageSession.cancel()
        }
    }

    private var header: some View {
        HStack {
            Button {
                manager.pendingAIAction = nil
                manager.detailItemID = nil
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .accessibilityLabel("Back to history")
            Spacer()
            TypeBadge(type: item.type)
            Text(item.date, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var imagePreview: some View {
        if let data = item.imagePNG, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 180)
                .frame(maxWidth: .infinity)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("Image preview")
        }
    }

    private var originalTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Content")
            Text(item.text ?? "")
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Recognized text")
                Spacer()
                ocrStatusLabel
            }
            switch item.ocrStatus {
            case .done:
                Text(item.ocrText ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button {
                        manager.copyString(item.ocrText ?? "")
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy recognized text")
                    Button("Retry") { manager.ocr.enqueue(item.id) }
                        .help("Run text recognition again")
                }
            case .noText:
                Text("No text found in this image.")
                    .foregroundStyle(.secondary)
                Button("Retry") { manager.ocr.enqueue(item.id) }
            case .failed:
                Label("Text recognition failed\(item.ocrError.map { " (\($0))" } ?? "").",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry") { manager.ocr.enqueue(item.id) }
            case .queued, .processing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(item.ocrStatus == .queued ? "Waiting to process…" : "Recognizing text…")
                        .foregroundStyle(.secondary)
                }
            case nil:
                Button {
                    manager.ocr.enqueue(item.id)
                } label: {
                    Label("Extract Text", systemImage: "text.viewfinder")
                }
                .accessibilityLabel("Extract text from this image")
            }
        }
    }

    @ViewBuilder
    private var ocrStatusLabel: some View {
        switch item.ocrStatus {
        case .done: Label("Done", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .noText: Label("No text", systemImage: "textformat.slash").font(.caption).foregroundStyle(.secondary)
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        case .queued: Label("Queued", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .processing: Label("Processing", systemImage: "gearshape").font(.caption).foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }

    // MARK: - AI text actions

    @ViewBuilder
    private var aiTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(item.type == .image ? "AI actions on extracted text" : "AI actions")
            if !config.enabled {
                aiSetupHint("Local AI actions are disabled.")
            } else if config.textModel.isEmpty {
                aiSetupHint("No text model selected.")
            } else {
                aiActionButtons
                customInstructionRow
                AIResultView(session: textSession, manager: manager,
                             emptyHint: nil, sourceLabel: "Result")
            }
        }
    }

    private var aiActionButtons: some View {
        HStack(spacing: 6) {
            Menu("Translate") {
                ForEach(AIAction.translateTargets, id: \.self) { target in
                    Button(target) { run(.translate(target: target)) }
                }
                Divider()
                TextField("Custom language", text: $customTarget)
                Button("Translate to custom language") {
                    let t = customTarget.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { run(.translate(target: t)) }
                }
            }
            .fixedSize()
            Button("Summarize") { run(.summarize) }
            Menu("Rewrite") {
                ForEach(AIAction.RewritePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { run(.rewrite(preset)) }
                }
            }
            .fixedSize()
            Button("Explain") { run(.explain) }
        }
        .disabled(textSession.running)
    }

    private var customInstructionRow: some View {
        HStack {
            TextField("Custom instruction (e.g. “turn into bullet points”)", text: $customInstruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runCustom() }
                .accessibilityLabel("Custom AI instruction")
            Button("Run") { runCustom() }
                .disabled(customInstruction.trimmingCharacters(in: .whitespaces).isEmpty || textSession.running)
        }
    }

    private func runCustom() {
        let instruction = customInstruction.trimmingCharacters(in: .whitespaces)
        guard !instruction.isEmpty else { return }
        run(.custom(instruction))
    }

    private func run(_ action: AIAction) {
        guard let content = sourceText, !content.isEmpty else { return }
        textSession.run(action: action, content: content, config: config)
    }

    private func runPendingActionIfAny() {
        guard let action = manager.pendingAIAction else { return }
        manager.pendingAIAction = nil
        if config.isReadyForText { run(action) }
    }

    // MARK: - Image analysis

    @ViewBuilder
    private var analyzeImageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Analyze image")
            if !config.enabled {
                aiSetupHint("Local AI actions are disabled.")
            } else if config.visionModel.isEmpty {
                aiSetupHint("No vision-capable model selected. Image analysis needs a local vision model (e.g. qwen2.5vl or llava).")
            } else {
                HStack {
                    TextField("Question about the image", text: $analysisPrompt)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { analyze(analysisPrompt) }
                        .accessibilityLabel("Question about the image")
                    Menu {
                        Button("Describe this image") { analyze("Describe this image.") }
                        Button("Explain this error") { analyze("Explain the error shown in this image.") }
                        Button("Explain this chart") { analyze("Explain the chart shown in this image.") }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .fixedSize()
                    .accessibilityLabel("Suggested questions")
                    Button("Ask") { analyze(analysisPrompt) }
                        .disabled(analysisPrompt.trimmingCharacters(in: .whitespaces).isEmpty || imageSession.running)
                }
                conversationView
                // While streaming, the partial answer shows inline; once it
                // finishes it moves into the conversation above.
                AIResultView(session: imageSession, manager: manager,
                             emptyHint: nil, sourceLabel: "Answer",
                             showOutputInline: imageSession.running,
                             showResultActions: false)
                if imageSession.finished && !imageSession.output.isEmpty {
                    HStack {
                        Button {
                            manager.copyString(imageSession.output)
                        } label: {
                            Label("Copy Result", systemImage: "doc.on.doc")
                        }
                        Button {
                            manager.append(ClipItem(id: UUID(), pinned: false, date: Date(), type: .text,
                                                    text: imageSession.output, html: nil, imagePNG: nil, files: nil))
                        } label: {
                            Label("Save to History", systemImage: "tray.and.arrow.down")
                        }
                        .help("Save the answer as a new history item; the original image is never modified")
                    }
                }
                if !imageSession.conversation.isEmpty && !imageSession.running {
                    HStack {
                        TextField("Follow-up question", text: $followUp)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { askFollowUp() }
                            .accessibilityLabel("Follow-up question about the image")
                        Button("Ask") { askFollowUp() }
                            .disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("This conversation is kept in memory only and is discarded when you leave this panel.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var conversationView: some View {
        // Completed turns; the in-progress answer streams in AIResultView below.
        let turns = imageSession.conversation.filter { $0.role == "assistant" || $0.role == "user" }
        if turns.contains(where: { $0.role == "assistant" }) || turns.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(turns.enumerated()), id: \.offset) { _, msg in
                    HStack(alignment: .top, spacing: 6) {
                        Text(msg.role == "user" ? "You:" : "AI:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(msg.content)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func analyze(_ prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, let png = item.imagePNG else { return }
        imageSession.analyzeImage(prompt: p, imagePNG: png, config: config)
    }

    private func askFollowUp() {
        let q = followUp.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let png = item.imagePNG else { return }
        followUp = ""
        imageSession.followUp(question: q, imagePNG: png, config: config)
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func aiSetupHint(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open AI Settings…") {
                NotificationCenter.default.post(name: .clipsterOpenSettings, object: nil)
            }
        }
    }
}

/// Shared result area: progress, streamed output, errors, and result actions.
struct AIResultView: View {
    @ObservedObject var session: AISession
    let manager: ClipboardManager
    var emptyHint: String?
    var sourceLabel: String
    var showOutputInline: Bool = true
    var showResultActions: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { session.cancel() }
                        .accessibilityLabel("Cancel generation")
                }
            }
            if let err = session.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Retry") { session.retry() }
            }
            if !session.output.isEmpty && showOutputInline {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(sourceLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("AI-generated — may contain mistakes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(session.output)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25)))
                }
                if session.finished && showResultActions {
                    HStack {
                        Button {
                            manager.copyString(session.output)
                        } label: {
                            Label("Copy Result", systemImage: "doc.on.doc")
                        }
                        Button {
                            manager.append(ClipItem(id: UUID(), pinned: false, date: Date(), type: .text,
                                                    text: session.output, html: nil, imagePNG: nil, files: nil))
                        } label: {
                            Label("Save to History", systemImage: "tray.and.arrow.down")
                        }
                        .help("Save the result as a new history item; the original is never modified")
                    }
                }
            }
        }
    }
}
