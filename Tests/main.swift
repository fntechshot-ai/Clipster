// Clipster test runner.
//
// The project is built with swiftc only (no Xcode), so XCTest / Swift Testing
// are unavailable. This is a plain executable with assertions: it exercises
// the data model, OCR queue, search and clipboard-coordination logic and exits
// non-zero on any failure. Run it with ./run_tests.sh.

import AppKit
import Foundation

// MARK: - Tiny assertion framework

var failures = 0
var checks = 0
var currentTest = ""

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    do {
        try body()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): threw \(error)")
    }
}

func expect(_ condition: Bool, _ message: String,
            file: String = #file, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL \(currentTest): \(message)  [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]")
    }
}

/// Pump the main run loop (drains main-queue async work) until `condition` or timeout.
@discardableResult
func pump(timeout: TimeInterval = 20, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

// MARK: - Fixtures

let tmpBase = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipsterTests-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpBase) }

var pasteboardCounter = 0
func freshManager(store: String = UUID().uuidString) -> ClipboardManager {
    pasteboardCounter += 1
    let pb = NSPasteboard(name: NSPasteboard.Name("com.francisconeto.Clipster.tests.\(UUID().uuidString)"))
    return ClipboardManager(pasteboard: pb,
                            storeURL: tmpBase.appendingPathComponent("\(store).json"))
}

func makeTextImagePNG(_ string: String, size: NSSize = NSSize(width: 700, height: 140)) -> Data {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 44, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    (string as NSString).draw(at: NSPoint(x: 24, y: 40), withAttributes: attrs)
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

func makeBlankImagePNG(size: NSSize = NSSize(width: 300, height: 200)) -> Data {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

func textItem(_ s: String, pinned: Bool = false) -> ClipItem {
    ClipItem(id: UUID(), pinned: pinned, date: Date(), type: .text,
             text: s, html: nil, imagePNG: nil, files: nil)
}

// MARK: - Data model / persistence

test("legacy history JSON (pre-OCR fields) still decodes") {
    let legacy = """
    [{"id":"11111111-1111-1111-1111-111111111111","pinned":true,
      "date":699999999.0,"type":"TXT","text":"hello old world"}]
    """
    let items = try JSONDecoder().decode([ClipItem].self, from: legacy.data(using: .utf8)!)
    expect(items.count == 1, "one item decoded")
    expect(items[0].text == "hello old world", "text preserved")
    expect(items[0].pinned, "pin preserved")
    expect(items[0].ocrStatus == nil, "no OCR status on legacy item")
    expect(items[0].ocrText == nil, "no OCR text on legacy item")
}

test("transient OCR states are not persisted as stuck work") {
    let m = freshManager(store: "transient")
    var a = textItem("x")
    a = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                 text: nil, html: nil, imagePNG: makeBlankImagePNG(), files: nil)
    m.append(a)
    m.setOCRTransientStatus(a.id, .processing)
    m.save() // simulate a save that happened to run mid-processing
    let m2 = ClipboardManager(pasteboard: NSPasteboard(name: NSPasteboard.Name("t.\(UUID())")),
                              storeURL: tmpBase.appendingPathComponent("transient.json"))
    m2.load()
    expect(m2.items.count == 1, "item survived reload")
    expect(m2.items.first?.ocrStatus == nil, "processing state reset to not-processed on load")
}

test("terminal OCR results survive a reload") {
    let m = freshManager(store: "terminal")
    let item = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                        text: nil, html: nil, imagePNG: makeBlankImagePNG(), files: nil)
    m.append(item)
    m.applyOCRResult(item.id, text: "permission denied", errorCategory: nil)
    let m2 = ClipboardManager(pasteboard: NSPasteboard(name: NSPasteboard.Name("t.\(UUID())")),
                              storeURL: tmpBase.appendingPathComponent("terminal.json"))
    m2.load()
    expect(m2.items.first?.ocrStatus == .done, "done status persisted")
    expect(m2.items.first?.ocrText == "permission denied", "ocr text persisted")
    expect(m2.items.first?.ocrEngine == OCRService.engineVersion, "engine version recorded")
}

// MARK: - Search

test("search is case- and diacritic-insensitive and covers OCR text") {
    expect(ClipboardManager.textMatches("Ação concluída", "acao"), "diacritic-insensitive match")
    expect(ClipboardManager.textMatches("plain ascii", "ASCII"), "case-insensitive match")
    expect(!ClipboardManager.textMatches(nil, "x"), "nil never matches")

    let m = freshManager()
    m.append(textItem("the quick brown fox"))
    let img = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                       text: nil, html: nil, imagePNG: makeBlankImagePNG(), files: nil)
    m.append(img)
    m.applyOCRResult(img.id, text: "Error: permissão negada no screenshot", errorCategory: nil)

    m.query = "permissao negada"
    expect(m.orderedItems.count == 1, "image found via its OCR text (diacritic-insensitive)")
    expect(m.orderedItems.first?.id == img.id, "the matching item is the image")
    m.query = "quick"
    expect(m.orderedItems.count == 1 && m.orderedItems.first?.type == .text, "text search still works")
    m.query = ""
    expect(m.orderedItems.count == 2, "clearing the query shows everything")
}

test("search snippet extraction") {
    let text = "first line\nthe error was: permission denied while opening the socket\nlast line"
    let snip = ClipboardManager.snippet(of: text, matching: "PERMISSION")
    expect(snip != nil, "snippet found")
    expect(snip?.localizedCaseInsensitiveContains("permission denied") == true, "snippet contains the match")
    expect(snip?.contains("\n") == false, "snippet is single-line")
    expect(ClipboardManager.snippet(of: "short", matching: "zzz") == nil, "no snippet when no match")
}

// MARK: - Append / dedupe / trim

test("append de-duplicates consecutive identical items and trims to maxItems") {
    let m = freshManager()
    let a = textItem("same")
    let id1 = m.append(a)
    let id2 = m.append(textItem("same"))
    expect(m.items.count == 1, "identical consecutive content deduplicated")
    expect(id1 == id2, "append returns the surviving item id")
    m.append(textItem("different"))
    expect(m.items.count == 2, "different content appended")

    m.maxItems = 20
    for i in 0..<30 { m.append(textItem("item \(i)")) }
    expect(m.items.count == 20, "history trimmed to maxItems")
}

// MARK: - Clipboard coordination

test("storeCapturedImage writes clipboard, stores once, and suppresses the watcher") {
    let pb = NSPasteboard(name: NSPasteboard.Name("com.francisconeto.Clipster.tests.suppress"))
    let m2 = ClipboardManager(pasteboard: pb, storeURL: tmpBase.appendingPathComponent("sup.json"))
    m2.autoOCR = false

    let png = makeBlankImagePNG()
    let id = m2.storeCapturedImage(png)
    expect(id != nil, "item stored while history is on")
    expect(m2.items.count == 1, "exactly one history item")
    expect(pb.data(forType: .png) != nil, "PNG present on the clipboard")
    expect(pb.data(forType: .tiff) != nil, "TIFF fallback present on the clipboard")

    m2.tick() // watcher must NOT re-capture Clipster's own write
    expect(m2.items.count == 1, "no duplicate from clipboard observation")

    pb.clearContents()
    pb.setString("external copy", forType: .string)
    m2.tick() // a real external change is still captured
    expect(m2.items.count == 2, "external clipboard change captured")
    expect(m2.items.first?.text == "external copy", "external text item on top")
}

test("storeCapturedText puts text on the clipboard and one image item in history") {
    let pb = NSPasteboard(name: NSPasteboard.Name("com.francisconeto.Clipster.tests.captext"))
    let m = ClipboardManager(pasteboard: pb, storeURL: tmpBase.appendingPathComponent("captext.json"))
    let png = makeBlankImagePNG()
    let id = m.storeCapturedText("recognized words", sourcePNG: png)
    expect(pb.string(forType: .string) == "recognized words", "text ready to paste")
    expect(pb.data(forType: .png) == nil, "no intermediate image on the clipboard")
    expect(m.items.count == 1, "one history item")
    expect(m.items.first?.type == .image, "the history item is the source image")
    expect(m.items.first?.ocrText == "recognized words", "OCR text attached")
    expect(m.items.first?.ocrStatus == .done, "status is done")
    expect(id == m.items.first?.id, "returned id matches")
    m.tick()
    expect(m.items.count == 1, "watcher suppressed — no duplicate text item")
}

test("paused history: capture writes the clipboard but stores nothing") {
    let pb = NSPasteboard(name: NSPasteboard.Name("com.francisconeto.Clipster.tests.paused"))
    let m = ClipboardManager(pasteboard: pb, storeURL: tmpBase.appendingPathComponent("paused.json"))
    m.isCapturing = false
    let idA = m.storeCapturedImage(makeBlankImagePNG())
    expect(idA == nil && m.items.isEmpty, "paused: image not persisted")
    expect(pb.data(forType: .png) != nil, "paused: image still on clipboard")
    let idB = m.storeCapturedText("abc", sourcePNG: makeBlankImagePNG())
    expect(idB == nil && m.items.isEmpty, "paused: text capture not persisted")
    expect(pb.string(forType: .string) == "abc", "paused: text still on clipboard")
}

// MARK: - OCR recognition (real Vision)

test("Vision OCR recognizes rendered text") {
    let png = makeTextImagePNG("Hello Clipster 1234")
    let result = OCRService.recognize(pngData: png)
    guard case .text(let t) = result else {
        expect(false, "expected .text, got \(result)")
        return
    }
    expect(t.localizedCaseInsensitiveContains("Clipster"), "recognized the word Clipster in: \(t)")
    expect(t.contains("1234"), "digits preserved in: \(t)")
}

test("Vision OCR reports no text for a blank image and failure for garbage") {
    expect(OCRService.recognize(pngData: makeBlankImagePNG()) == .noText, "blank image → noText")
    if case .failed = OCRService.recognize(pngData: Data([0x00, 0x01, 0x02])) {
        // expected
    } else {
        expect(false, "garbage data should fail")
    }
}

// MARK: - OCR queue behavior

test("auto OCR queue processes new images and updates status") {
    let m = freshManager()
    m.autoOCR = true
    let item = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                        text: nil, html: nil, imagePNG: makeTextImagePNG("Queue Test"), files: nil)
    let id = m.append(item)
    let done = pump { m.item(id)?.ocrStatus == .done }
    expect(done, "OCR completed via the queue")
    expect(m.item(id)?.ocrText?.localizedCaseInsensitiveContains("queue") == true,
           "queued recognition found the text: \(m.item(id)?.ocrText ?? "nil")")
}

test("deleting an item during OCR discards the late result without resurrecting it") {
    let m = freshManager()
    m.autoOCR = true
    var ids: [UUID] = []
    for i in 0..<3 {
        let item = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                            text: nil, html: nil, imagePNG: makeTextImagePNG("Victim \(i)"), files: nil)
        ids.append(m.append(item))
    }
    // Delete the newest (head of queue order varies; delete one that is queued or processing).
    if let victim = m.item(ids[1]) { m.delete(victim) }
    let settled = pump {
        ids.filter { m.item($0) != nil }.allSatisfy { m.item($0)?.ocrStatus == .done } && !m.ocr.isBusy
    }
    expect(settled, "remaining items finished")
    expect(m.item(ids[1]) == nil, "deleted item stayed deleted")
    expect(m.items.count == 2, "no orphan or resurrected records")
}

test("backfill targets only images that need OCR") {
    let m = freshManager()
    m.autoOCR = false
    let fresh = m.append(ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                                  text: nil, html: nil, imagePNG: makeTextImagePNG("Backfill"), files: nil))
    let doneItem = ClipItem(id: UUID(), pinned: false, date: Date(), type: .image,
                            text: nil, html: nil, imagePNG: makeBlankImagePNG(), files: nil)
    let doneID = m.append(doneItem)
    m.applyOCRResult(doneID, text: "already done", errorCategory: nil)

    let needed = m.imageItemsNeedingOCR(engine: OCRService.engineVersion)
    expect(needed == [fresh], "only the unprocessed image needs OCR, got \(needed.count)")

    m.ocr.startBackfill()
    let finished = pump { m.item(fresh)?.ocrStatus == .done && !m.ocr.backfillRunning }
    expect(finished, "backfill completed")
    expect(m.item(doneID)?.ocrText == "already done", "already-done result untouched")
}

// MARK: - AI actions

test("AI action prompts delimit untrusted content and carry parameters") {
    let t = AIAction.translate(target: "Portuguese (Portugal)")
    expect(t.systemPrompt.contains("Portuguese (Portugal)"), "translate target in prompt")
    expect(t.systemPrompt.contains("untrusted"), "guardrail present")
    let c = AIAction.custom("make it rhyme")
    expect(c.systemPrompt.contains("make it rhyme"), "custom instruction embedded")
    expect(c.systemPrompt.contains("untrusted"), "guardrail present for custom")
    for action in [AIAction.summarize, .rewrite(.shorter), .explain] {
        expect(action.systemPrompt.contains("untrusted"), "\(action.title) carries guardrail")
    }
}

// MARK: - Apple on-device model (runs only where Apple Intelligence is available)

test("Apple Intelligence bridge streams deltas (skipped when unavailable)") {
    guard AppleFMBridge.isSupported else {
        print("  … skipped: \(AppleFMBridge.statusDescription)")
        return
    }
    var collected = ""
    var finished = false
    var streamError: Error?
    let stream = AppleFMBridge.stream(system: "Reply with exactly one short sentence.",
                                      prompt: "Say hello.")
    Task {
        do {
            for try await delta in stream { collected += delta }
        } catch {
            streamError = error
        }
        finished = true
    }
    let done = pump(timeout: 60) { finished }
    expect(done, "generation finished in time")
    expect(streamError == nil, "no stream error: \(String(describing: streamError))")
    expect(!collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           "assembled a non-empty response from deltas: \(collected)")
}

// MARK: - Done

print("\n\(checks) checks, \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
