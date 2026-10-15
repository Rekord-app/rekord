import Foundation
import RecorderCore

func testMeetings() throws {
    for legacy in [nil, false, true] as [Bool?] {
        let name = "rekord-policy-tests-\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        if let legacy { defaults.set(legacy,forKey: "meetingAutoRecord") }
        precondition(!MeetingRecordingPolicy.enabled(defaults))
        MeetingRecordingPolicy.migrate(defaults)
        precondition(!MeetingRecordingPolicy.enabled(defaults))
        XCTAssertEqual(defaults.object(forKey: "meetingLegacyAutoRecord") as? Bool,legacy)
        MeetingRecordingPolicy.setEnabled(true,in: defaults)
        MeetingRecordingPolicy.migrate(defaults)
        precondition(MeetingRecordingPolicy.enabled(defaults))
        MeetingRecordingPolicy.setEnabled(false,in: defaults)
        precondition(!MeetingRecordingPolicy.enabled(defaults))
    }
    // Sentences: split at punctuation and pauses, shifted by the track offset; punctuation re-attached.
    let words = [TranscriptWord(text: " Hallo",start: 0.2,end: 0.5),TranscriptWord(text: " Anna",start: 0.6,end: 0.9),TranscriptWord(text: ".",start: 0.9,end: 0.95),
                 TranscriptWord(text: " Wie",start: 1.2,end: 1.4),TranscriptWord(text: " geht's?",start: 1.5,end: 1.9),
                 TranscriptWord(text: " Kurze",start: 5.0,end: 5.3),TranscriptWord(text: " Pause",start: 5.4,end: 5.8)]
    let mine = Transcript.sentences(from: words,speaker: .me,offset: 0.1)
    XCTAssertEqual(mine.map(\.text),["Hallo Anna.","Wie geht's?","Kurze Pause"])
    XCTAssertEqual(mine[0].start,0.3,accuracy: 1e-9); XCTAssertEqual(mine[2].end,5.9,accuracy: 1e-9)
    let theirs = Transcript.sentences(from: [TranscriptWord(text: "Gut, danke.",start: 2.0,end: 2.6)],speaker: .other,offset: 0.05)
    let transcript = Transcript(engine: "test",locale: "de_DE",sentences: Transcript.merged([theirs,mine]))
    XCTAssertEqual(transcript.sentences.map(\.speaker),[.me,.me,.other,.me])
    XCTAssertEqual(transcript.turns.count,3)   // two own sentences < 4 s apart form one turn
    var meeting = Meeting(title: "Erstgespräch",contact: "Anna Schmidt",company: "Müller GmbH",startedAt: Date(timeIntervalSince1970: 1_760_000_000),consent: true,ownName: "Nikita")
    meeting.hasSystemAudio = true; meeting.duration = 600
    let text = transcript.promptText(for: meeting)
    precondition(text.contains("Nikita: [00:00] Hallo Anna. [00:01] Wie geht's?") && text.contains("Anna Schmidt: [00:02] Gut, danke."),text)
    precondition(transcript.markdown(for: meeting).contains("**Anna Schmidt** [00:02]: Gut, danke."))

    // Echo: the microphone repeats the other side (speakers, no headphones) → dropped; real own speech stays.
    let echo = [TranscriptSentence(speaker: .other,start: 10,end: 13,text: "Wir verschicken etwa zwölfhundert Angebote im Jahr."),
                TranscriptSentence(speaker: .me,start: 10.2,end: 13.1,text: "verschicken etwa zwölfhundert Angebote im Jahr"),
                TranscriptSentence(speaker: .me,start: 13.5,end: 15,text: "Wie lange dauert ein Angebot heute?"),
                TranscriptSentence(speaker: .me,start: 40,end: 43,text: "verschicken etwa zwölfhundert Angebote im Jahr")]
    XCTAssertEqual(Transcript.removingEcho(echo).map(\.start),[10,13.5,40])
    // Persistence: folder name from date and title, round trip, listing newest first, no path separators.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rekord-meeting-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try MeetingsFolder.newDirectory(for: meeting,in: root)
    precondition(directory.lastPathComponent.hasSuffix("Erstgespräch"),directory.lastPathComponent)
    try meeting.save(to: directory); try transcript.save(to: directory,meeting: meeting)
    XCTAssertEqual(try Meeting.load(from: directory),meeting)
    XCTAssertEqual(try Transcript.load(from: directory),transcript)
    var later = Meeting(title: "A/B: Test",startedAt: meeting.startedAt.addingTimeInterval(3600),consent: false,ownName: "Nikita")
    later.duration = 1
    let second = try MeetingsFolder.newDirectory(for: later,in: root); try later.save(to: second)
    precondition(!second.lastPathComponent.contains("/") && second.lastPathComponent.contains("A-B- Test"),second.lastPathComponent)
    XCTAssertEqual(MeetingsFolder.all(in: root),[second,directory])
    XCTAssertEqual(later.otherName,"Gesprächspartner"); XCTAssertNil(later.consentConfirmedAt)

    // Summary request: model, fallback, structured output, transcript but no audio; consent note without system audio.
    let body = try JSONSerialization.jsonObject(with: MeetingSummarizer.requestBody(meeting: meeting,transcript: transcript,glossary: ["Claude","OpenRouter"])) as! [String: Any]
    XCTAssertEqual(body["model"] as? String,"claude-sonnet-5-5"); XCTAssertEqual(body["max_tokens"] as? Int,16000)
    XCTAssertEqual(body["fallbacks"] as? String,"default")
    let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
    let schema = format?["schema"] as? [String: Any]
    XCTAssertEqual(format?["type"] as? String,"json_schema"); XCTAssertEqual(schema?["additionalProperties"] as? Bool,false)
    XCTAssertEqual(Set(schema?["required"] as? [String] ?? []),Set((schema?["properties"] as? [String: Any] ?? [:]).keys))
    let system = body["system"] as? String ?? ""
    precondition(system.contains("nicht angesprochen") && system.contains("Claude, OpenRouter") && !system.contains("nur Nikitas Mikrofon"))
    let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    precondition(user.contains("<transkript>") && user.contains("Gut, danke.") && user.contains("Müller GmbH"))
    let micOnly = try JSONSerialization.jsonObject(with: MeetingSummarizer.requestBody(meeting: later,transcript: transcript,glossary: [])) as! [String: Any]
    precondition((micOnly["system"] as? String ?? "").contains("Aufgenommen wurde nur Nikitas Mikrofon"))

    // Response parsing: last text block, refusal and truncation surface as errors.
    let summary = MeetingSummary(shortSummary: "Kurz.",company: "Müller GmbH",contact: "Anna Schmidt, GF",situation: "nicht angesprochen",mainPain: "Angebote dauern 3 Tage",
                                 currentProcess: "Excel",budgetSignal: "nicht angesprochen",decisionMaker: "Anna Schmidt",objections: [.init(quote: "Das ist mir zu teuer.",timestamp: "04:12")],
                                 interest: 4,interestReason: "Will ein Angebot.",nextStep: .init(action: "Angebot schicken",date: "2026-10-20",owner: "me"),
                                 actionItems: [.init(title: "Angebot schicken",owner: "me",dueDate: "2026-10-20")],followUpDraft: "Hallo Anna, …")
    let json = String(decoding: try JSONEncoder().encode(summary),as: UTF8.self)
    let response = try JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn","content": [["type": "thinking","thinking": ""],["type": "text","text": json]]])
    XCTAssertEqual(try MeetingSummarizer.parse(response),summary)
    for reason in ["refusal","max_tokens"] {
        let data = try JSONSerialization.data(withJSONObject: ["stop_reason": reason,"content": []])
        XCTAssertThrowsError(_ = try MeetingSummarizer.parse(data))
    }
    try summary.save(to: directory,meeting: meeting)
    let markdown = try String(contentsOf: directory.appendingPathComponent(MeetingFile.summaryText),encoding: .utf8)
    precondition(markdown.contains("**Interesse: 4/5**") && markdown.contains("> „Das ist mir zu teuer.“ [04:12]") && markdown.contains("Angebot schicken · 2026-10-20 · Nikita"),markdown)
    print("PASS: meetings (sentences, merge, persistence, summary request/parse/markdown)")
}
