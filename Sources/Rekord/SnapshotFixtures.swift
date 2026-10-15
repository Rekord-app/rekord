import AppKit
import ImageIO
import UniformTypeIdentifiers
import RecorderCore

/// Synthetic meetings and guides for `--ui-snapshot`, written into a temporary folder so layout reviews never
/// show or touch the user's own calls and guides. All names, companies and quotes are invented.
enum SnapshotFixtures {
    /// Six meetings across today / this week / earlier, with the states the list has to handle.
    @MainActor static func makeMeetings(in root: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let now = Date(), calendar = Calendar.current
        func at(daysAgo: Int,hour: Int,minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day,value: -daysAgo,to: now)!
            return calendar.date(bySettingHour: hour,minute: minute,second: 0,of: day)!
        }
        struct Spec { let title: String; let contact: String; let company: String; let date: Date; let duration: Double; let app: String; let interest: Int; let status: MeetingStatus; let nextStep: String; let date2: String }
        let specs = [
            Spec(title: "",contact: "Petra Wagner",company: "Wagner Sanitär GmbH",date: at(daysAgo: 0,hour: 10,minute: 30),duration: 1872,app: "Google Meet",interest: 5,status: .done,nextStep: "Angebot für den KI-Setter schicken",date2: "Freitag"),
            Spec(title: "",contact: "Jonas Keller",company: "Keller & Sohn Elektro",date: at(daysAgo: 0,hour: 14,minute: 0),duration: 1544,app: "Zoom",interest: 3,status: .done,nextStep: "Zweiter Call mit dem Geschäftsführer",date2: "nächste Woche"),
            Spec(title: "Teams 16:05",contact: "",company: "",date: at(daysAgo: 0,hour: 16,minute: 5),duration: 420,app: "Microsoft Teams",interest: 0,status: .transcribing,nextStep: "",date2: ""),
            Spec(title: "",contact: "Sabine Roth",company: "Roth Immobilien",date: at(daysAgo: 1,hour: 11,minute: 15),duration: 2410,app: "Google Meet",interest: 4,status: .done,nextStep: "Demo des Lead-Magneten zeigen",date2: "Dienstag"),
            Spec(title: "",contact: "Markus Lindner",company: "Lindner Logistik",date: at(daysAgo: 3,hour: 9,minute: 0),duration: 980,app: "FaceTime",interest: 2,status: .done,nextStep: "",date2: ""),
            Spec(title: "Zoom 15:30",contact: "",company: "",date: at(daysAgo: 5,hour: 15,minute: 30),duration: 1230,app: "Zoom",interest: 0,status: .failed,nextStep: "",date2: ""),
            Spec(title: "",contact: "Anna Brandt",company: "Brandt Steuerberatung",date: at(daysAgo: 16,hour: 13,minute: 0),duration: 3105,app: "Zoom",interest: 4,status: .done,nextStep: "Pilot für drei Mandanten aufsetzen",date2: "Monatsende"),
            Spec(title: "",contact: "Tim Vogel",company: "Vogel Fenster",date: at(daysAgo: 41,hour: 10,minute: 0),duration: 1480,app: "Google Meet",interest: 1,status: .done,nextStep: "",date2: ""),
        ]
        var urls: [URL] = []
        for spec in specs {
            var meeting = Meeting(title: spec.title,contact: spec.contact,company: spec.company,startedAt: spec.date,consent: true,ownName: "Nikita")
            meeting.app = spec.app; meeting.duration = spec.duration; meeting.hasSystemAudio = true; meeting.status = spec.status
            if spec.status == .done { meeting.transcribedWith = "SpeechTranscriber"; meeting.summarizedWith = MeetingSummarizer.model; meeting.processingSeconds = 12.7 }
            if spec.status == .failed { meeting.error = "Claude-API antwortet mit 529: overloaded" }
            let directory = try MeetingsFolder.newDirectory(for: meeting,in: root)
            try meeting.save(to: directory)
            if spec.status == .done {
                let transcript = Transcript(engine: "SpeechTranscriber",locale: "de-DE",sentences: [
                    TranscriptSentence(speaker: .me,start: 1.2,end: 6.8,text: "Hallo \(spec.contact.split(separator: " ").first ?? "")! Schön, dass es geklappt hat. Ich nehme den Call für meine Notizen auf, ist das okay für dich?"),
                    TranscriptSentence(speaker: .other,start: 7.4,end: 9.1,text: "Ja klar, kein Problem."),
                    TranscriptSentence(speaker: .me,start: 9.8,end: 18.3,text: "Super. Erzähl mal, wie läuft bei euch gerade die Anfragenbearbeitung? Wer nimmt die Anrufe und Mails entgegen?"),
                    TranscriptSentence(speaker: .other,start: 19.0,end: 41.6,text: "Das macht im Moment meine Kollegin im Büro, aber die ist nur vormittags da. Nachmittags bleibt vieles liegen, und am nächsten Tag haben die Leute oft schon woanders angefragt. Wir verlieren da sicher jede Woche zwei, drei Aufträge."),
                    TranscriptSentence(speaker: .me,start: 42.0,end: 49.5,text: "Verstehe. Und was wäre für euch ein guter Ablauf? Was soll passieren, wenn eine Anfrage reinkommt?"),
                    TranscriptSentence(speaker: .other,start: 50.2,end: 71.0,text: "Am liebsten sofort eine Antwort mit den wichtigsten Fragen, und dann ein Termin im Kalender. Ich habe nur Sorge, dass das zu technisch klingt und die Kunden merken, dass da keiner sitzt."),
                    TranscriptSentence(speaker: .me,start: 71.6,end: 88.0,text: "Das ist ein berechtigter Punkt. Die Texte schreiben wir in eurem Ton, und bei allem, was unklar ist, übernimmt wieder ein Mensch. Wollen wir das an einem echten Beispiel durchgehen?"),
                    TranscriptSentence(speaker: .other,start: 88.6,end: 92.0,text: "Ja, gerne. Was würde das kosten?"),
                ])
                try transcript.save(to: directory,meeting: meeting)
                let summary = MeetingSummary(
                    shortSummary: "\(spec.company) verliert Anfragen, weil nachmittags niemand antwortet. \(spec.contact) will eine automatische Erstantwort mit Terminbuchung, hat aber Sorge, dass es unpersönlich wirkt.",
                    company: spec.company,contact: spec.contact,
                    situation: "Anfragen kommen per Telefon und Mail, werden nur vormittags bearbeitet.",
                    mainPain: "Zwei bis drei verlorene Aufträge pro Woche durch späte Antworten.",
                    currentProcess: "Bürokraft beantwortet Anfragen manuell, nachmittags bleibt alles liegen.",
                    budgetSignal: spec.interest >= 4 ? "Fragt aktiv nach dem Preis; Budget im vierstelligen Bereich wirkt realistisch." : "nicht angesprochen",
                    decisionMaker: spec.interest >= 3 ? "\(spec.contact) entscheidet selbst." : "nicht angesprochen",
                    objections: spec.interest >= 3 ? [MeetingSummary.Objection(quote: "Ich habe nur Sorge, dass das zu technisch klingt und die Kunden merken, dass da keiner sitzt.",timestamp: "00:50")] : [],
                    interest: spec.interest,interestReason: spec.interest >= 4 ? "Konkreter Schmerz, fragt nach Preis und nächstem Schritt." : (spec.interest == 3 ? "Interessiert, aber Entscheidung hängt an einer weiteren Person." : "Wenig Druck, kein nächster Schritt vereinbart."),
                    nextStep: MeetingSummary.NextStep(action: spec.nextStep,date: spec.date2,owner: "me"),
                    actionItems: spec.nextStep.isEmpty ? [] : [MeetingSummary.ActionItem(title: "Beispiel-Antworten im Ton von \(spec.company) vorbereiten",owner: "me",dueDate: spec.date2),
                                                               MeetingSummary.ActionItem(title: "Zugang zum Mail-Postfach klären",owner: "other",dueDate: "")],
                    followUpDraft: "Hallo \(spec.contact.split(separator: " ").first ?? ""),\n\ndanke für das offene Gespräch heute. Ich fasse kurz zusammen: Anfragen bleiben nachmittags liegen, und ihr verliert dadurch Aufträge. Vorschlag: eine automatische Erstantwort in eurem Ton plus Terminbuchung, bei Unklarheiten übernimmt ein Mensch.\n\nIch schicke dir bis \(spec.date2.isEmpty ? "Ende der Woche" : spec.date2) zwei Beispiel-Antworten.\n\nViele Grüße\nNikita")
                try summary.save(to: directory,meeting: meeting)
            }
            urls.append(directory)
        }
        return urls
    }

    /// Three guides with synthetic step images, one with an automation brief.
    @MainActor static func makeGuides(in root: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let now = Date(), calendar = Calendar.current
        func at(daysAgo: Int,hour: Int) -> Date { calendar.date(bySettingHour: hour,minute: 20,second: 0,of: calendar.date(byAdding: .day,value: -daysAgo,to: now)!)! }
        struct StepSpec { let text: String; let note: String?; let role: String; let label: String; let app: String; let url: String?; let time: Double }
        let flows: [(title: String,date: Date,duration: Double,brief: Bool,steps: [StepSpec])] = [
            ("Rechnung in lexoffice anlegen",at(daysAgo: 0,hour: 9),214,true,[
                StepSpec(text: "Öffne in lexoffice den Bereich „Verkauf“ und klicke auf „Rechnungen“.",note: nil,role: "Link",label: "Rechnungen",app: "Google Chrome",url: "https://app.lexoffice.de/vouchers",time: 8.4),
                StepSpec(text: "Klicke oben rechts auf „Neue Rechnung“.",note: "Wenn der Kunde schon angelegt ist, erscheint er beim Tippen im Feld.",role: "Button",label: "Neue Rechnung",app: "Google Chrome",url: "https://app.lexoffice.de/vouchers",time: 15.1),
                StepSpec(text: "Trage im Feld „Kunde“ den Firmennamen ein und wähle den Eintrag aus der Liste.",note: nil,role: "TextField",label: "Kunde",app: "Google Chrome",url: "https://app.lexoffice.de/vouchers/new",time: 24.8),
                StepSpec(text: "Füge die Position mit Beschreibung, Menge und Preis hinzu.",note: "Die Umsatzsteuer rechnet lexoffice automatisch dazu.",role: "Button",label: "Position hinzufügen",app: "Google Chrome",url: "https://app.lexoffice.de/vouchers/new",time: 61.0),
                StepSpec(text: "Klicke auf „Speichern und versenden“ und prüfe die Vorschau.",note: nil,role: "Button",label: "Speichern und versenden",app: "Google Chrome",url: "https://app.lexoffice.de/vouchers/new",time: 180.2),
            ]),
            ("Neuen Lead im CRM anlegen",at(daysAgo: 2,hour: 15),142,false,[
                StepSpec(text: "Klicke in der Seitenleiste auf „Leads“.",note: nil,role: "Button",label: "Leads",app: "Scale OS",url: nil,time: 5.0),
                StepSpec(text: "Klicke auf „Neuer Lead“ und trage Name und Firma ein.",note: nil,role: "Button",label: "Neuer Lead",app: "Scale OS",url: nil,time: 12.6),
                StepSpec(text: "Wähle die Quelle „Instagram“ und speichere.",note: "Die Quelle entscheidet, welche Follow-up-Sequenz startet.",role: "PopUpButton",label: "Quelle",app: "Scale OS",url: nil,time: 40.3),
            ]),
            ("Wochenbericht aus Numbers exportieren",at(daysAgo: 12,hour: 11),98,false,[
                StepSpec(text: "Öffne die Tabelle „Wochenbericht“ in Numbers.",note: nil,role: "Button",label: "Wochenbericht",app: "Numbers",url: nil,time: 4.2),
                StepSpec(text: "Wähle im Menü „Ablage“ den Punkt „Exportieren“ → „PDF“.",note: nil,role: "MenuItem",label: "PDF…",app: "Numbers",url: nil,time: 20.9),
            ]),
        ]
        var urls: [URL] = []
        for flow in flows {
            let directory = try GuidesFolder.newDirectory(title: flow.title,date: flow.date,in: root)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(GuideFile.images),withIntermediateDirectories: true)
            var steps: [GuideStep] = []
            for (i,spec) in flow.steps.enumerated() {
                let element = GuideElement(role: spec.role,roleDescription: spec.role == "Button" ? "Taste" : nil,title: spec.label,frame: GuideRect(x: 0.62,y: 0.18+Double(i)*0.11,width: 0.16,height: 0.045))
                var step = GuideStep(action: spec.role == "TextField" ? .type : .click,text: spec.text,element: element,appName: spec.app,bundleID: nil,windowTitle: flow.title,url: spec.url,time: spec.time,position: Point(0.7,0.2+Double(i)*0.11))
                step.note = spec.note
                let name = String(format: "images/step-%02d.png",i+1)
                try writeSyntheticScreenshot(to: directory.appendingPathComponent(name),highlight: element.frame!,label: spec.label,app: spec.app,index: i)
                step.image = name; step.autoRedacted = true
                if i == 2 { step.redactions = [GuideRedaction(rect: GuideRect(x: 0.2,y: 0.5,width: 0.2,height: 0.03),reason: "email")] }
                steps.append(step)
            }
            var guide = Guide(title: flow.title,createdAt: flow.date,duration: flow.duration,steps: steps)
            guide.textsBy = flow.brief ? MeetingSummarizer.model : "template"
            guide.summary = "So legst du eine Rechnung an, ohne etwas zu vergessen."
            if flow.brief { guide.frequencyPerWeek = 5 }
            try guide.save(to: directory)
            if flow.brief {
                let brief = """
                {"version":1,"guideID":"\(guide.id)","title":"\(flow.title)","summary":"Vier der fünf Schritte lassen sich über die lexoffice-API automatisieren; nur die Prüfung der Vorschau bleibt beim Menschen.","groups":[
                {"title":"Rechnung anlegen und Kunde wählen","steps":[1,2,3],"automatable":"ja","method":"api","tools":"lexoffice Public API, n8n","apiStatus":"bekannt","reason":"lexoffice bietet eine dokumentierte REST-API für Rechnungen und Kontakte.","effort":"niedrig","effortHours":3,"seconds":52.6},
                {"title":"Positionen eintragen","steps":[4],"automatable":"teilweise","method":"n8n","tools":"n8n, Google Sheets","apiStatus":"bekannt","reason":"Positionen kommen aus dem Auftrag; Sonderfälle brauchen eine Prüfung.","effort":"mittel","effortHours":6,"seconds":119.2},
                {"title":"Vorschau prüfen und versenden","steps":[5],"automatable":"nein","method":"human","tools":"","apiStatus":"prüfen","reason":"Die Freigabe soll bewusst bei einer Person bleiben.","effort":"niedrig","effortHours":0,"seconds":20}],
                "firstStep":"Mit dem n8n-Workflow für Schritt 1–3 starten: Kunde und Rechnung per API anlegen.","minutesPerRun":3.43,"savedMinutesPerRun":1.87,"runsPerWeek":5,"hoursPerMonth":0.68,"euroPerMonth":34,"hourlyRate":50,"model":"\(MeetingSummarizer.model)","createdAt":"\(ISO8601DateFormatter().string(from: flow.date))"}
                """
                try brief.write(to: directory.appendingPathComponent(GuideFile.brief),atomically: true,encoding: .utf8)
            }
            urls.append(directory)
        }
        return urls
    }

    /// A plausible app window (header, sidebar, text lines) with the clicked element framed, as the guide images look.
    private static func writeSyntheticScreenshot(to url: URL,highlight: GuideRect,label: String,app: String,index: Int) throws {
        let width = 1600, height = 1000
        guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0.96,green: 0.96,blue: 0.97,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: w,height: h))
        context.setFillColor(CGColor(red: 0.13,green: 0.15,blue: 0.2,alpha: 1)); context.fill(CGRect(x: 0,y: h-64,width: w,height: 64))
        context.setFillColor(CGColor(red: 0.9,green: 0.9,blue: 0.92,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 260,height: h-64))
        context.setFillColor(CGColor(red: 1,green: 1,blue: 1,alpha: 1))
        for row in 0..<7 { context.fill(CGRect(x: 300,y: h-150-CGFloat(row)*96,width: w-560,height: 64)) }
        context.setFillColor(CGColor(red: 0.75,green: 0.76,blue: 0.8,alpha: 1))
        for row in 0..<7 { context.fill(CGRect(x: 320,y: h-128-CGFloat(row)*96,width: 300+CGFloat((row*37)%200),height: 14)) }
        for row in 0..<8 { context.fill(CGRect(x: 24,y: h-110-CGFloat(row)*44,width: 150,height: 12)) }
        // The clicked element (filled button) and the click ring around it, like GuideImages draws them.
        let rect = CGRect(x: highlight.x*w,y: h-(highlight.y+highlight.height)*h,width: highlight.width*w,height: highlight.height*h)
        context.setFillColor(CGColor(red: 0.2,green: 0.45,blue: 0.95,alpha: 1)); context.fill(rect)
        context.setStrokeColor(CGColor(red: 1,green: 0.27,blue: 0.2,alpha: 1)); context.setLineWidth(5); context.stroke(rect.insetBy(dx: -8,dy: -8))
        context.setStrokeColor(CGColor(red: 1,green: 0.27,blue: 0.2,alpha: 0.5)); context.setLineWidth(3); context.strokeEllipse(in: CGRect(x: rect.midX-26,y: rect.midY-26,width: 52,height: 52))
        guard let image = context.makeImage(),let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { return }
        CGImageDestinationAddImage(destination,image,nil); CGImageDestinationFinalize(destination)
    }
}
