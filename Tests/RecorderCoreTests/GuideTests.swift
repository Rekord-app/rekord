import Foundation
import CoreGraphics
import CoreText
import ImageIO
import RecorderCore

func testGuides() throws {
    // Steps: double click, repeated click on the same element, focus click on a container, click + typing.
    let button = GuideElement(role: "Button",title: "Neue Rechnung")
    let field = GuideElement(role: "TextField",placeholder: "Kundennummer")
    let events = [
        GuideEvent(time: 1.0,kind: .click,position: Point(0.5,0.5),element: GuideElement(role: "WebArea",title: "Rechnungen – lexoffice"),appName: "Google Chrome"),          // focus only, labeled with the page title
        GuideEvent(time: 2.0,kind: .click,position: Point(0.2,0.1),element: button,appName: "Google Chrome",url: "https://app.lexoffice.de/rechnungen"),
        GuideEvent(time: 3.0,kind: .click,position: Point(0.2,0.1),element: button,appName: "Google Chrome"),                                // same element < 2 s
        GuideEvent(time: 5.0,kind: .click,position: Point(0.4,0.3),element: field,appName: "Google Chrome"),
        GuideEvent(time: 7.5,kind: .typed,position: Point(0.4,0.3),element: field,appName: "Google Chrome",characters: 6),
        GuideEvent(time: 8.0,kind: .click,position: Point(0.6,0.6),element: GuideElement(role: "Cell",value: "Müller GmbH"),appName: "Finder"),
        GuideEvent(time: 8.3,kind: .click,position: Point(0.601,0.601),element: GuideElement(role: "Cell",value: "Müller GmbH"),appName: "Finder"), // double click
        GuideEvent(time: 9.0,kind: .rightClick,position: Point(0.6,0.6),element: GuideElement(role: "Cell",value: "Müller GmbH"),appName: "Finder"),
        GuideEvent(time: 10.0,kind: .click,position: Point(0.9,0.9),element: GuideElement(role: "Button",title: "Stopp"),bundleID: "dev.sapunov.FocusRecorder"), // Rekord itself
        GuideEvent(time: 11.0,kind: .click,position: Point(0.3,0.3),element: GuideElement(role: "SecureTextField",secure: true),appName: "Safari"),
    ]
    let steps = GuideBuilder.steps(from: GuideCapture(events: events,accessibility: true))
    XCTAssertEqual(steps.map(\.action),[.click,.type,.doubleClick,.rightClick,.click])
    XCTAssertEqual(steps[0].text,"Klicke auf die Schaltfläche „Neue Rechnung“.")
    XCTAssertEqual(steps[1].text,"Klicke in das Feld „Kundennummer“ und gib den Wert ein.")
    XCTAssertEqual(steps[2].text,"Doppelklicke auf die Zeile „Müller GmbH“.")
    XCTAssertEqual(steps[4].text,"Gib dein Passwort ein.")
    let sie = GuideBuilder.steps(from: GuideCapture(events: events,accessibility: true),address: .sie)
    XCTAssertEqual(sie[0].text,"Klicken Sie auf die Schaltfläche „Neue Rechnung“.")
    // Label priority: title, attached label, description, placeholder, value (non-editable only), help.
    XCTAssertEqual(GuideElement(role: "Button",description: "Speichern",help: "Tipp").label,"Speichern")
    XCTAssertEqual(GuideElement(role: "TextField",value: "geheim",placeholder: "Name").label,"Name")
    XCTAssertEqual(GuideElement(role: "TextField",value: "geheim").label,nil)
    XCTAssertEqual(GuideElement(role: "Button",title: "  button ",labelText: "Senden").label,"Senden")

    // Speech: words after the previous click (+0.8 s) up to 0.8 s after this click; earlier words are the intro.
    var guide = Guide(title: "Test",createdAt: Date(timeIntervalSince1970: 1_760_000_000),duration: 20,steps: steps)
    let words = [TranscriptWord(text: "Heute",start: 0.1,end: 0.4),TranscriptWord(text: "zeige",start: 0.5,end: 0.8),
                 TranscriptWord(text: "Rechnung",start: 1.7,end: 2.1),TranscriptWord(text: "Kundennummer",start: 4.0,end: 4.6)]
    GuideBuilder.assignSpeech(words,offset: 0,to: &guide)
    XCTAssertEqual(guide.intro,"Heute zeige")
    XCTAssertEqual(guide.steps[0].speech,"Rechnung"); XCTAssertEqual(guide.steps[1].speech,"Kundennummer")

    // Sensitive text: e-mail, IBAN, phone, card (Luhn), password dots; masked for anything leaving the Mac.
    let sample = "Mail max.mustermann@example.com, IBAN DE89 3704 0044 0532 0130 00, Tel. +49 171 2345678, Karte 4111 1111 1111 1111, PW ••••••, Rechnung 2026-1043"
    XCTAssertEqual(Set(SensitiveText.matches(in: sample).map(\.reason)),["email","iban","phone","card","password"])
    let masked = SensitiveText.masked(sample)
    precondition(!masked.contains("mustermann") && !masked.contains("3704") && !masked.contains("2345678") && masked.contains("Rechnung 2026-1043"),masked)
    XCTAssertEqual(SensitiveText.strippedURL("https://user:pw@app.example.com/kunden/12?email=a@b.de#x"),"https://app.example.com/kunden/12")

    // What goes to Claude: element names, apps, URL without query, masked speech; no values of text fields.
    guide.steps[1].speech = "meine Mail ist max.mustermann@example.com"
    let body = String(decoding: try GuideAI.textsRequestBody(guide),as: UTF8.self)
    precondition(body.contains("Neue Rechnung") && body.contains("app.lexoffice.de") && !body.contains("mustermann") && !body.contains("image"),body)

    // Brief: time saving from step durations and frequency, not from the model.
    var timed = Guide(title: "Rechnung",duration: 30,steps: steps)
    timed.frequencyPerWeek = 10
    let seconds = AutomationBrief.stepSeconds(timed)
    XCTAssertEqual(seconds.count,steps.count)
    XCTAssertEqual(seconds[0],steps[1].time-steps[0].time,accuracy: 1e-9)

    // Persistence round trip with schema check, markdown.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-guide-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try GuidesFolder.newDirectory(title: "Rechnung anlegen",in: root)
    guide.steps[0].image = "images/step-01.jpg"
    try guide.save(to: directory)
    let loaded = try Guide.load(from: directory)
    XCTAssertEqual(loaded,guide)
    XCTAssertEqual(GuidesFolder.all(in: root),[directory])
    let json = try String(contentsOf: directory.appendingPathComponent(GuideFile.guide),encoding: .utf8)
    precondition(json.contains("\"schema\" : \"rekord.guide\"") && json.contains("\"schemaVersion\" : 1"),json)
    let markdown = try String(contentsOf: directory.appendingPathComponent(GuideFile.markdown),encoding: .utf8)
    precondition(markdown.contains("## 1. Klicke auf die Schaltfläche „Neue Rechnung“.") && markdown.contains("![Schritt 1](images/step-01.jpg)"),markdown)

    // OCR redaction on a synthetic screenshot with visible test data, then render and PDF.
    let image = try syntheticScreen(lines: ["Kunde: Max Mustermann","E-Mail: max.mustermann@example.com","IBAN: DE89 3704 0044 0532 0130 00","Betrag: 1.200,00 €"])
    let regions = try GuideImages.sensitiveRegions(in: image)
    XCTAssertEqual(Set(regions.map(\.reason)),["email","iban"])
    precondition(regions.allSatisfy { $0.rect.x > 0.1 && $0.rect.y > 0.1 && $0.rect.y < 0.6 },"\(regions)")
    let rendered = GuideImages.render(image,click: Point(0.5,0.8),redactions: regions)!
    // The OCR on the rendered image must not find the data any more.
    XCTAssertEqual(try GuideImages.sensitiveRegions(in: rendered).count,0)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"),withIntermediateDirectories: true)
    try GuideImages.writeJPEG(rendered,to: directory.appendingPathComponent("images/step-01.jpg"))
    let pdf = directory.appendingPathComponent(GuideFile.pdf)
    try GuidePDF.write(guide,directory: directory,to: pdf)
    let document = CGPDFDocument(pdf as CFURL)!
    precondition(document.numberOfPages >= 1,"pdf pages")
    if let artifacts = ProcessInfo.processInfo.environment["REKORD_TEST_ARTIFACTS"] {
        let out = URL(fileURLWithPath: artifacts); try? FileManager.default.createDirectory(at: out,withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("guide-test.pdf")); try? FileManager.default.copyItem(at: pdf,to: out.appendingPathComponent("guide-test.pdf"))
        try? GuideImages.writeJPEG(rendered,to: out.appendingPathComponent("guide-redacted.jpg"))
    }
    print("PASS: guides (step rules, labels, speech, masking, Claude payload text-only, persistence, OCR redaction, PDF)")
}

/// A light "app window" with black text lines, 1440×900.
func syntheticScreen(lines: [String]) throws -> CGImage {
    let w = 1440, h = 900
    let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(gray: 0.97,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: w,height: h))
    let font = CTFontCreateWithName("Helvetica" as CFString,30,nil)
    for (i,line) in lines.enumerated() {
        let text = NSAttributedString(string: line,attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05,alpha: 1)])
        context.textPosition = CGPoint(x: 220,y: Double(h)-200-Double(i)*80)
        CTLineDraw(CTLineCreateWithAttributedString(text),context)
    }
    return context.makeImage()!
}

/// Word times as SpeechTranscriber reports them (first word stretched over the pause, lone "." token).
func testGuideSpeechAnchors() {
    func w(_ t: String,_ s: Double,_ e: Double) -> TranscriptWord { TranscriptWord(text: t,start: s,end: e) }
    let words = [w("Dann",9.9,10.4),w("CRM",10.5,10.9),w("ein.",11.22,11.5),w("Jetzt",11.52,12.6),w("den",12.66,12.9),w("Betrag",12.96,13.5),w("haben",15.42,15.9),w(".",16.08,16.1),w("Speicher",16.2,17.1),w("erst",17.22,17.4),w("Entwurf.",17.82,18.4)]
    var guide = Guide(title: "t",duration: 30,steps: [11.68,15.95,20.31].map { GuideStep(action: .click,text: "",element: nil,appName: nil,bundleID: nil,windowTitle: nil,url: nil,time: $0,position: .center) })
    GuideBuilder.assignSpeech(words,offset: 0,to: &guide)
    XCTAssertEqual(guide.steps.map { $0.speech ?? "" },["Dann CRM ein.","Jetzt den Betrag haben.","Speicher erst Entwurf."])
    print("PASS: guide speech anchors (stretched first word, lone punctuation)")
}
