import AppKit
import ApplicationServices
import AVFoundation
import RecorderCore

/// `--guide-check <dir> --scenario web|chrome|native|electron [--no-claude]`: guide acceptance without a person.
/// Opens a test target with fake data only (local HTML page in Safari or Chrome, TextEdit, Cursor on an empty
/// folder), maximizes its window so no other window is recorded, starts a guide recording, speaks a narration
/// with `say` (the microphone hears it), clicks real UI elements found through Accessibility, types into a field,
/// stops and checks: element names in step texts, images exist, OCR finds no e-mail/IBAN in any image although the
/// raw frames contain them, and which hosts the app talked to. Report: `<dir>/guide-report-<scenario>.txt`.
@MainActor enum GuideDiagnostics {
    struct Target { let label: String; var type: String? = nil; var say: String; var role: String? = nil }

    static func run(arguments: [String]) async {
        if let r = arguments.firstIndex(of: "--guide-replay"),arguments.count > r+1 { await replay(root: URL(fileURLWithPath: arguments[r+1]),claude: !arguments.contains("--no-claude"),
                                                                                       image: arguments.firstIndex(of: "--image").flatMap { arguments.count > $0+1 ? URL(fileURLWithPath: arguments[$0+1]) : nil }); return }
        guard let i = arguments.firstIndex(of: "--guide-check"),arguments.count > i+1 else { return }
        let root = URL(fileURLWithPath: arguments[i+1])
        let scenario = arguments.firstIndex(of: "--scenario").flatMap { arguments.count > $0+1 ? arguments[$0+1] : nil } ?? "web"
        var lines: [String] = []
        let report = root.appendingPathComponent("guide-report-\(scenario).txt")
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: report,atomically: true,encoding: .utf8); print(value) }
        func check(_ ok: Bool,_ text: String) { log("\(ok ? "PASS" : "FAIL") \(text)") }
        try? FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        log("START guide acceptance \(scenario) \(Date().ISO8601Format()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard GuideAccessibility.trusted else {
            log("FAIL Accessibility permission missing for \(Bundle.main.bundlePath). Grant Rekord in System Settings → Privacy & Security → Accessibility.")
            return
        }
        log("PASS Accessibility permission granted")
        do {
            let (app,targets) = try await prepare(scenario: scenario,root: root)
            log("INFO target \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")), \(targets.count) planned clicks")
            let store = GuideStore(root: root.appendingPathComponent("Anleitungen"))
            if arguments.contains("--no-claude") { store.skipClaude = true }
            store.start()
            for _ in 0..<100 where store.phase != .recording { try await Task.sleep(nanoseconds: 100_000_000) }
            guard store.phase == .recording else { log("FAIL recording did not start: \(store.error ?? "unknown")"); return }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            speak("Ich zeige dir kurz, wie das geht."); try await Task.sleep(nanoseconds: 2_500_000_000)
            var clicked: [String] = []
            for target in targets {
                app.activate()
                speak(target.say)
                try await Task.sleep(nanoseconds: 1_800_000_000)
                guard let element = find(target,in: app.processIdentifier), let frame = frame(of: element) else { log("WARN element „\(target.label)“ not found"); continue }
                click(CGPoint(x: frame.midX,y: frame.midY))
                clicked.append(target.label)
                try await Task.sleep(nanoseconds: 900_000_000)
                if let text = target.type { type(text); try await Task.sleep(nanoseconds: 700_000_000) }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var connections = Set<String>()
            let stopped = Date()
            store.stop()
            for _ in 0..<3000 where store.phase != .idle { connections.formUnion(MeetingDiagnostics.remoteEndpoints()); try await Task.sleep(nanoseconds: 100_000_000) }
            log("INFO processing took \(String(format: "%.1f",Date().timeIntervalSince(stopped))) s\(store.notice.map { " · notice: \($0)" } ?? "")\(store.error.map { " · error: \($0)" } ?? "")")
            guard let directory = store.selected, let guide = try? Guide.load(from: directory) else { log("FAIL no guide written"); return }
            log("INFO guide \(directory.path)")
            let capture = try GuideCapture.load(from: directory)
            log("INFO \(capture.events.count) raw events, \(guide.steps.count) steps, texts by \(guide.textsBy)")
            for (n,step) in guide.steps.enumerated() {
                log("  \(n+1). [\(step.action.rawValue)] \(step.text)  ← \(step.element?.role ?? "-") „\(step.element?.label ?? "")“ · \(step.appName ?? "") \(step.url ?? "")\(step.speech.map { " · gesagt: \($0)" } ?? "")")
            }
            // Element names: every clicked target must appear in the text of a step.
            let texts = guide.steps.map { $0.text.lowercased() }
            let named = clicked.filter { label in texts.contains { $0.contains(label.lowercased()) } }
            let share = clicked.isEmpty ? 0 : Double(named.count)/Double(clicked.count)
            check(share >= 0.9,"element names in step texts: \(named.count)/\(clicked.count) (\(Int(share*100)) %)\(named.count < clicked.count ? " missing: \(clicked.filter { !named.contains($0) })" : "")")
            check(guide.steps.allSatisfy { $0.image.map { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } ?? false },"every step has an image")
            // Redaction: raw frames contain the fake data, the stored images do not.
            var raw = Set<String>(), leaked: [String] = []
            for step in guide.steps {
                let frame = try await GuideImages.frame(of: directory.appendingPathComponent(guide.video),at: step.time-GuideImages.leadTime)
                raw.formUnion(try GuideImages.sensitiveRegions(in: frame).map(\.reason))
                if let path = step.image, let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(path) as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) {
                    let found = try GuideImages.sensitiveRegions(in: image)
                    if !found.isEmpty { leaked.append("\(path): \(found.map(\.reason))") }
                }
            }
            log("INFO sensitive data visible in raw frames: \(raw.sorted())")
            check(leaked.isEmpty,"no e-mail/IBAN/phone/card/password in stored images\(leaked.isEmpty ? "" : ": \(leaked)")")
            log("INFO remote connections during processing: \(connections.sorted())")
            let words = (try? GuideWords.load(from: directory))?.words.count ?? 0
            log("INFO transcript words: \(words)")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }

    /// Everything after the click capture, without the Accessibility permission: records only the Safari window
    /// with the fake test page (window capture, nothing else on screen is recorded) while `say` narrates, then feeds
    /// a synthetic click capture (elements as the Accessibility API reports them for this page) into the normal
    /// processing: transcript, steps, images, OCR redaction, Claude texts, brief, PDF. Report: `<dir>/guide-replay.txt`.
    static func replay(root: URL,claude: Bool,image: URL? = nil) async {
        var lines: [String] = []
        let report = root.appendingPathComponent("guide-replay.txt")
        func log(_ value: String) { lines.append(value); try? lines.joined(separator: "\n").write(to: report,atomically: true,encoding: .utf8); print(value) }
        func check(_ ok: Bool,_ text: String) { log("\(ok ? "PASS" : "FAIL") \(text)") }
        do {
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            log("START guide replay \(Date().ISO8601Format()) · accessibility \(GuideAccessibility.trusted)")
            let page = root.appendingPathComponent("testfirma.html")
            try fakePage.write(to: page,atomically: true,encoding: .utf8)
            var source: CaptureSource?
            if image == nil {
                _ = try await launch(bundle: "com.apple.Safari",arguments: [],open: page)
                for _ in 0..<40 where source == nil {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    source = try await ScreenRecorder.sources().first { $0.window?.owningApplication?.bundleIdentifier == "com.apple.Safari" && ($0.window?.title ?? "").contains("Testfirma") }
                }
                guard source != nil else { log("FAIL Safari window with the test page not found (screen recording permission?)"); return }
                log("INFO recording window \(source!.title)")
            } else { log("INFO offline: video built from \(image!.lastPathComponent) (screen locked or asleep)") }
            let guides = GuideStore(root: root.appendingPathComponent("Anleitungen"))
            guides.skipClaude = !claude
            let directory = try GuidesFolder.newDirectory(title: "Replay",in: guides.root)
            let script = ["Ich zeige dir, wie wir bei der Testfirma eine Rechnung anlegen.","Zuerst gehst du oben auf Rechnungen.","Dann trägst du die Kundennummer aus dem CRM ein.",
                          "Jetzt den Betrag, den wir im Angebot vereinbart haben.","Speicher erst einen Entwurf, damit nichts verloren geht.","Und zum Schluss auf Rechnung versenden. Achtung, das geht sofort raus."]
            // Narration as the microphone track: each line spoken by `say` into a file, 0.8 s pauses (the lid may be
            // closed, so the built-in microphone is not used). The normal processing transcribes it locally.
            let (narration,times) = try await synthesizeNarration(script,to: directory.appendingPathComponent("microphone.m4a"))
            if let source {
                let recorder = ScreenRecorder()
                try await recorder.start(source: source,directory: directory,fps: 30,withCamera: false,withAudio: false,withMicrophone: false,mode: .studio)
                try await Task.sleep(nanoseconds: UInt64((narration+1)*1_000_000_000))
                var project = try await recorder.stop(name: "Replay")
                project.zooms = []; project.hasMicrophone = true; project.microphoneOffset = 0; try project.save(to: directory)
            } else if let image {
                let size = try writeStillVideo(image,duration: narration+1,to: directory.appendingPathComponent("screen.mov"))
                var project = Project(name: "Replay",duration: narration+1,width: size.0,height: size.1,fps: 30)
                project.hasMicrophone = true; project.microphoneOffset = 0; try project.save(to: directory)
            }
            // Elements as Safari reports them for the test page (role, title, label); positions in the window.
            let rechnungen = GuideElement(role: "Link",title: "Rechnungen",frame: GuideRect(x: 0.274,y: 0.017,width: 0.071,height: 0.028))
            let kunde = GuideElement(role: "TextField",placeholder: "z. B. K-1001",labelText: "Kundennummer",frame: GuideRect(x: 0.043,y: 0.224,width: 0.432,height: 0.046))
            let betrag = GuideElement(role: "TextField",labelText: "Betrag in Euro",frame: GuideRect(x: 0.043,y: 0.311,width: 0.432,height: 0.046))
            let entwurf = GuideElement(role: "Button",title: "Entwurf speichern",frame: GuideRect(x: 0.043,y: 0.461,width: 0.125,height: 0.048))
            let senden = GuideElement(role: "Button",title: "Rechnung versenden",frame: GuideRect(x: 0.174,y: 0.461,width: 0.144,height: 0.048))
            let url = SensitiveText.strippedURL(page.absoluteString)
            func event(_ i: Int,_ kind: GuideEventKind,_ element: GuideElement,_ chars: Int? = nil) -> GuideEvent {
                let f = element.frame!
                return GuideEvent(time: times[i]+(kind == .typed ? 0.6 : 0),kind: kind,position: Point(f.x+f.width/2,f.y+f.height/2),element: element,appName: "Safari",bundleID: "com.apple.Safari",windowTitle: "Rechnungen – Testfirma",url: url,characters: chars)
            }
            let capture = GuideCapture(events: [event(1,.click,rechnungen),event(2,.click,kunde),event(2,.typed,kunde,6),event(3,.click,betrag),event(3,.typed,betrag,4),event(4,.click,entwurf),event(5,.click,senden)],accessibility: true)
            try capture.save(to: directory)
            var connections = Set<String>()
            let clock = Date()
            let watcher = Task { var seen = Set<String>(); while !Task.isCancelled { seen.formUnion(MeetingDiagnostics.remoteEndpoints()); try? await Task.sleep(nanoseconds: 300_000_000) }; return seen }
            do { try await guides.process(directory: directory) } catch { log("WARN processing: \(error.localizedDescription)") }
            watcher.cancel(); connections.formUnion(await watcher.value)
            log("INFO processing \(String(format: "%.1f",Date().timeIntervalSince(clock))) s\(guides.notice.map { " · notice: \($0)" } ?? "")")
            var guide = try Guide.load(from: directory)
            log("INFO \(guide.steps.count) steps, texts by \(guide.textsBy), title „\(guide.title)“")
            for (n,step) in guide.steps.enumerated() { log("  \(n+1). [\(step.action.rawValue)] \(step.text)\(step.note.map { " · Tipp: \($0)" } ?? "")\(step.warning.map { " · Achtung: \($0)" } ?? "")\(step.speech.map { " · gesagt: \($0)" } ?? "")") }
            let labels = ["Rechnungen","Kundennummer","Betrag in Euro","Entwurf speichern","Rechnung versenden"]
            let named = zip(labels,guide.steps).filter { $1.text.contains($0) }.count
            check(guide.steps.count == 5 && named >= 5,"5 steps, element name in \(named)/5 texts")
            var raw = Set<String>(), leaked: [String] = []
            for step in guide.steps {
                let frame = try await GuideImages.frame(of: directory.appendingPathComponent(guide.video),at: step.time-GuideImages.leadTime)
                raw.formUnion(try GuideImages.sensitiveRegions(in: frame).map(\.reason))
                if let path = step.image, let src = CGImageSourceCreateWithURL(directory.appendingPathComponent(path) as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(src,0,nil) {
                    let found = try GuideImages.sensitiveRegions(in: image); if !found.isEmpty { leaked.append("\(path): \(found.map(\.reason))") }
                }
            }
            check(raw.contains("email") && raw.contains("iban"),"raw frames show the fake e-mail and IBAN: \(raw.sorted())")
            check(leaked.isEmpty,"stored images contain no e-mail/IBAN/phone/card\(leaked.isEmpty ? "" : ": \(leaked)")")
            if claude, let key = GuideStore.claudeKey(), !key.isEmpty {
                guide.frequencyPerWeek = 15; try guide.save(to: directory)
                let brief = try await GuideAI.writeBrief(for: guide,apiKey: key)
                try brief.save(to: directory)
                connections.formUnion(MeetingDiagnostics.remoteEndpoints())
                log("INFO brief: \(brief.groups.count) groups · \(brief.savingLine)")
                for g in brief.groups { log("  - \(g.title) \(g.steps) \(g.automatable) \(g.method) API \(g.apiStatus) \(g.effort)") }
                check(brief.hoursPerMonth != nil && Set(brief.groups.flatMap(\.steps)) == Set(1...guide.steps.count),"brief covers every step and has a time saving")
            }
            try GuidePDF.write(guide,directory: directory,to: directory.appendingPathComponent(GuideFile.pdf))
            check(CGPDFDocument(directory.appendingPathComponent(GuideFile.pdf) as CFURL)?.numberOfPages ?? 0 >= 1,"PDF written")
            log("INFO remote connections: \(connections.sorted())")
            log("INFO guide \(directory.path)")
            log("DONE")
        } catch { log("FAIL \(error.localizedDescription)") }
    }

    /// H.264 movie showing one still image (offline acceptance when the screen cannot be recorded).
    static func writeStillVideo(_ image: URL,duration: Double,to output: URL) throws -> (Int,Int) {
        guard let source = CGImageSourceCreateWithURL(image as CFURL,nil), let frame = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw RecorderError.message("Bild fehlt") }
        let w = frame.width/2*2, h = frame.height/2*2
        let writer = try AVAssetWriter(outputURL: output,fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: w,AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: w,kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_32BGRA,nil,&buffer)
        guard let buffer else { throw RecorderError.message("Puffer fehlt") }
        CVPixelBufferLockBaseAddress(buffer,[])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),width: w,height: h,bitsPerComponent: 8,bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(frame,in: CGRect(x: 0,y: 0,width: w,height: h))
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let frames = Int(duration*30)
        for n in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buffer,withPresentationTime: CMTime(value: CMTimeValue(n),timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.message("Video nicht geschrieben") }
        return (w,h)
    }
    /// Lines spoken by `say -v Anna` into one AAC file with 0.8 s pauses; returns its length and the end time of each line.
    static func synthesizeNarration(_ lines: [String],to output: URL) async throws -> (Double,[Double]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-narration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecorderError.message("Audio-Spur fehlt") }
        var cursor = CMTime(seconds: 0.8,preferredTimescale: 600), ends: [Double] = []
        for (i,line) in lines.enumerated() {
            let file = folder.appendingPathComponent("\(i).aiff")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v","Anna","-o",file.path,line]; try p.run(); p.waitUntilExit()
            let asset = AVURLAsset(url: file)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero,duration: duration),of: source,at: cursor)
            cursor = cursor+duration; ends.append(cursor.seconds+0.2)
            cursor = cursor+CMTime(seconds: 0.8,preferredTimescale: 600)
        }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition,presetName: AVAssetExportPresetAppleM4A) else { throw RecorderError.message("Export fehlt") }
        try await export.export(to: output,as: .m4a)
        return (cursor.seconds,ends)
    }

    // MARK: Scenarios (fake data only)

    static let fakePage = """
    <!doctype html><html lang="de"><head><meta charset="utf-8"><title>Rechnungen – Testfirma</title>
    <style>body{font:18px -apple-system,sans-serif;margin:0;background:#f5f6f8;color:#1c1d21}nav{background:#1f3b63;color:#fff;padding:16px 28px;display:flex;gap:26px;align-items:center}nav a{color:#fff;text-decoration:none}main{padding:28px 40px;display:grid;grid-template-columns:1fr 1fr;gap:28px}section{background:#fff;border-radius:12px;padding:22px}label{display:block;margin:14px 0 6px;font-size:15px;color:#555}input,select{font:inherit;padding:9px 11px;width:100%;box-sizing:border-box;border:1px solid #ccd;border-radius:8px}button{font:inherit;padding:11px 18px;border-radius:9px;border:0;background:#2563eb;color:#fff;margin:16px 8px 0 0}.data p{margin:10px 0}</style></head>
    <body><nav><strong>Testfirma GmbH</strong><a href="#">Dashboard</a><a href="#">Kunden</a><a href="#" id="r">Rechnungen</a></nav>
    <main><section><h2>Neue Rechnung</h2><label for="kd">Kundennummer</label><input id="kd" placeholder="z. B. K-1001">
    <label for="betrag">Betrag in Euro</label><input id="betrag"><label for="pw">Passwort zur Freigabe</label><input id="pw" type="password">
    <button type="button">Entwurf speichern</button><button type="button">Rechnung versenden</button></section>
    <section class="data"><h2>Kundendaten</h2><p>Ansprechpartner: Max Mustermann</p><p>E-Mail: max.mustermann@example.com</p>
    <p>IBAN: DE89 3704 0044 0532 0130 00</p><p>Telefon: +49 171 2345678</p></section></main></body></html>
    """

    static func prepare(scenario: String,root: URL) async throws -> (NSRunningApplication,[Target]) {
        switch scenario {
        case "web","chrome":
            let page = root.appendingPathComponent("testfirma.html")
            try fakePage.write(to: page,atomically: true,encoding: .utf8)
            let bundle = scenario == "chrome" ? "com.google.Chrome" : "com.apple.Safari"
            let app = try await launch(bundle: bundle,arguments: scenario == "chrome" ? ["--new-window",page.absoluteString] : [],open: scenario == "chrome" ? nil : page)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            maximize(app)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return (app,[Target(label: "Rechnungen",say: "Zuerst gehst du oben auf Rechnungen."),
                         Target(label: "Kundennummer",type: "K-1001",say: "Dann trägst du die Kundennummer aus dem CRM ein."),
                         Target(label: "Betrag in Euro",type: "1200",say: "Jetzt den Betrag, den wir im Angebot vereinbart haben."),
                         Target(label: "Entwurf speichern",say: "Speicher erst einen Entwurf, damit nichts verloren geht."),
                         Target(label: "Rechnung versenden",say: "Und zum Schluss auf Rechnung versenden. Achtung, das geht sofort an den Kunden.")])
        case "native":
            let file = root.appendingPathComponent("Angebot Testfirma.txt")
            try "Angebot für Testfirma GmbH\nKontakt: max.mustermann@example.com\nIBAN DE89 3704 0044 0532 0130 00\n".write(to: file,atomically: true,encoding: .utf8)
            let app = try await launch(bundle: "com.apple.TextEdit",arguments: [],open: file)
            try await Task.sleep(nanoseconds: 2_500_000_000)
            maximize(app)
            return (app,[Target(label: "Format",say: "Oben im Menü öffnest du Format.",role: "MenuBarItem"),
                         Target(label: "In reinen Text umwandeln",say: "Dann wählst du In reinen Text umwandeln.",role: "MenuItem"),
                         Target(label: "Ablage",say: "Jetzt das Menü Ablage.",role: "MenuBarItem"),
                         Target(label: "Duplizieren",say: "Und Duplizieren, damit das Original bleibt.",role: "MenuItem")])
        case "electron":
            let folder = root.appendingPathComponent("electron-test")
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            try "# Testfirma\nKontakt: max.mustermann@example.com\n".write(to: folder.appendingPathComponent("README.md"),atomically: true,encoding: .utf8)
            let app = try await launch(bundle: "com.todesktop.230313mzl4w4u92",arguments: [],open: folder)
            try await Task.sleep(nanoseconds: 6_000_000_000)
            maximize(app)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return (app,[Target(label: "README.md",say: "Links im Explorer öffnest du die README.",role: nil),
                         Target(label: "Search",say: "Dann die Suche in der Seitenleiste.",role: nil),
                         Target(label: "Explorer",say: "Und zurück zum Explorer.",role: nil)])
        default: throw RecorderError.message("Unbekanntes Szenario \(scenario)")
        }
    }
    static func launch(bundle: String,arguments: [String],open file: URL?) async throws -> NSRunningApplication {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw RecorderError.message("\(bundle) ist nicht installiert.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = arguments; configuration.activates = true
        if let file { return try await NSWorkspace.shared.open([file],withApplicationAt: url,configuration: configuration) }
        return try await NSWorkspace.shared.openApplication(at: url,configuration: configuration)
    }
    /// Front window fills the visible screen area, so no other window ends up in the recording.
    static func maximize(_ app: NSRunningApplication) {
        app.activate()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame, full = screen.frame
        var position = CGPoint(x: visible.minX,y: full.maxY-visible.maxY), size = visible.size
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&window) == .success || AXUIElementCopyAttributeValue(element,kAXMainWindowAttribute as CFString,&window) == .success,
              let window else { return }
        let w = window as! AXUIElement
        if let p = AXValueCreate(.cgPoint,&position) { AXUIElementSetAttributeValue(w,kAXPositionAttribute as CFString,p) }
        if let s = AXValueCreate(.cgSize,&size) { AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,s) }
    }

    // MARK: Input

    static func speak(_ text: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v","Anna",text]; try? process.run()
    }
    static func click(_ point: CGPoint) {
        CGEvent(mouseEventSource: nil,mouseType: .mouseMoved,mouseCursorPosition: point,mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(120_000)
        CGEvent(mouseEventSource: nil,mouseType: .leftMouseDown,mouseCursorPosition: point,mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: nil,mouseType: .leftMouseUp,mouseCursorPosition: point,mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    static func type(_ text: String) {
        for character in text {
            var units = Array(String(character).utf16)
            let down = CGEvent(keyboardEventSource: nil,virtualKey: 0,keyDown: true), up = CGEvent(keyboardEventSource: nil,virtualKey: 0,keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: units.count,unicodeString: &units); up?.keyboardSetUnicodeString(stringLength: units.count,unicodeString: &units)
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap); usleep(40_000)
        }
    }

    // MARK: Accessibility search

    static func string(_ element: AXUIElement,_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value as? String
    }
    static func frame(of element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&p) == .success, AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&s) == .success else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue,.cgPoint,&point); AXValueGetValue(s as! AXValue,.cgSize,&size)
        return size.width > 0 && size.height > 0 ? CGRect(origin: point,size: size) : nil
    }
    /// Breadth-first search for a visible element whose title, description, value or label starts with the target label.
    static func find(_ target: Target,in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
        AXUIElementSetAttributeValue(app,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        var queue: [AXUIElement] = [], visited = 0
        // Open menus first (menu items live below the menu bar), then the windows.
        var menuBar: CFTypeRef?
        if AXUIElementCopyAttributeValue(app,kAXMenuBarAttribute as CFString,&menuBar) == .success, let menuBar { queue.append(menuBar as! AXUIElement) }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&windows) == .success, let list = windows as? [AXUIElement] { queue += list }
        let wanted = target.label.lowercased()
        while !queue.isEmpty, visited < 6000 {
            let element = queue.removeFirst(); visited += 1
            let role = (string(element,kAXRoleAttribute) ?? "").replacingOccurrences(of: "AX",with: "",options: .anchored)
            let names = [string(element,kAXTitleAttribute),string(element,kAXDescriptionAttribute),string(element,kAXValueAttribute),string(element,kAXPlaceholderValueAttribute)].compactMap { $0?.lowercased() }
            var titleElement: CFTypeRef?
            let label = AXUIElementCopyAttributeValue(element,kAXTitleUIElementAttribute as CFString,&titleElement) == .success ? titleElement.flatMap { string($0 as! AXUIElement,kAXValueAttribute)?.lowercased() } : nil
            let matches = (names + [label].compactMap { $0 }).contains { $0 == wanted || $0.hasPrefix(wanted+" ") || $0.hasPrefix(wanted+" (") }
            let interactive = !["StaticText","Group","Heading"].contains(role) || role == target.role
            if matches, interactive, target.role == nil || role == target.role, frame(of: element) != nil { return element }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXChildrenAttribute as CFString,&children) == .success, let list = children as? [AXUIElement] { queue += list }
        }
        return nil
    }
}
