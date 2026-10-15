import Foundation
import RecorderCore

// Tools that need the running app (share token in the Keychain, Claude key, recorder hardware, confirmation
// dialogs, the open editor). They go through `rekord://call` with a key-protected request file (AppCall); the app
// is started in the background if needed. Destructive actions need `confirm: true`.

/// Runs one operation in the app and returns its result.
func appCall(_ op: String,_ arguments: [String: Any] = [:],timeout: TimeInterval = 120) async throws -> [String: Any] {
    let id = UUID().uuidString
    try AppCall.writeRequest(id: id,op: op,arguments: arguments.filter { !($0.value is NSNull) })
    try openInApp(AppCall.url(op: op,id: id))
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        try await Task.sleep(nanoseconds: 250_000_000)
        if let outcome = AppCall.takeResult(id: id) {
            guard outcome.ok else { throw ToolError(message: outcome.error ?? "Rekord hat den Auftrag abgelehnt.") }
            return outcome.result
        }
    }
    throw ToolError(message: "Rekord hat nicht rechtzeitig geantwortet. Läuft die App (recorder status)?")
}
/// Copies the listed keys from the tool arguments (absent keys stay absent, explicit null stays null).
func pick(_ args: [String: Any],_ keys: [String]) -> [String: Any] {
    var result: [String: Any] = [:]
    for key in keys where args.keys.contains(key) { result[key] = args[key] }
    return result
}
let confirmProperty: [String: Any] = ["type": "boolean","description": "Bestätigung für Aktionen, die etwas löschen, verwerfen oder Links sperren."]
let meetingProperty: [String: Any] = ["type": "string","description": "Pfad oder Ordnername aus list_meetings. Ohne Angabe: das neueste Meeting."]
let guideProperty: [String: Any] = ["type": "string","description": "Pfad oder Ordnername aus list_guides. Ohne Angabe: die neueste Anleitung."]

let appTools: [Tool] = [
    Tool(name: "manage_library",description: "Bibliothek ordnen: list_folders (Ordner mit Anzahl), create_folder (name), rename_folder (folder, name), dissolve_folder (folder; Aufnahmen bleiben erhalten), move (recording, folder; ohne folder = kein Ordner), trash (recording, confirm; in den Papierkorb, wiederherstellbar), forget_recent (recording aus der Zuletzt-Liste). Ordner sind normale Finder-Ordner in ~/Movies/Rekord.",
         properties: ["action": ["type": "string","enum": ["list_folders","create_folder","rename_folder","dissolve_folder","move","trash","forget_recent"]],
                      "recording": recordingProperty,"folder": ["type": "string","description": "Name des Ordners."],"name": ["type": "string","description": "Neuer Ordnername."],"confirm": confirmProperty],
         required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        if action == "list_folders" {
            let folders = Library.folders(in: recordingsFolder).map { ["folder": $0.lastPathComponent,"path": $0.path,"recordings": Library.projects(directlyIn: $0).count] }
            return [text(["root": recordingsFolder.path,"without_folder": Library.projects(directlyIn: recordingsFolder).count,"folders": folders])]
        }
        guard ["create_folder","rename_folder","dissolve_folder","move","trash","forget_recent"].contains(action) else { throw ToolError(message: "Unbekannte Aktion \(action)") }
        var call = pick(args,["folder","name","confirm"])
        if ["move","trash","forget_recent"].contains(action) {
            guard (args["recording"] as? String).map({ !$0.isEmpty && $0 != "latest" }) == true else { throw ToolError(message: "recording ausdrücklich angeben (Pfad oder Ordnername), nicht latest.") }
            call["recording"] = try resolve(args).path
        }
        return [text(try await appCall("library.\(action)",call))]
    },
    Tool(name: "manage_shares",description: "Geteilte Links verwalten (über die App, Token bleibt im Schlüsselbund): list (Videos, Anleitungslinks, Video-Angebote mit Ablaufdatum und zugehöriger Aufnahme), set_expiry (video_id, days; days null = dauerhaft behalten), revoke (video_id oder guide_id; ohne confirm nur Vorschau, was alles gesperrt würde).",
         properties: ["action": ["type": "string","enum": ["list","set_expiry","revoke"]],"video_id": ["type": "string"],"guide_id": ["type": "string"],
                      "days": ["type": ["integer","null"],"description": "Tage bis zum Ablauf (1–3650) oder null für dauerhaft."],"confirm": confirmProperty],required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        guard ["list","set_expiry","revoke"].contains(action) else { throw ToolError(message: "action: list, set_expiry oder revoke") }
        if action == "set_expiry", !args.keys.contains("days") { throw ToolError(message: "days angeben (Zahl oder null für dauerhaft).") }
        return [text(try await appCall("shares.\(action)",pick(args,["video_id","guide_id","days","confirm"]),timeout: 180))]
    },
    Tool(name: "video_offers",description: "Video-Angebote (persönlicher Link mit Titel, Nachricht und Termin-Button, optional Wiedergabe-Statistik): list, create (recording muss geteilt sein, oder video_id; title; startet mit der gespeicherten Angebots-Vorlage, optional recipient, message, booking_url, tracking, tracking_mode, sender, button_title, accent, notify_on_first_open), update (offer_id + Felder), stats (offer_id: Öffnungen, abgespielte Abschnitte, Klicks), set_expiry (offer_id, days oder null), revoke und clear_stats (offer_id, confirm).",
         properties: ["action": ["type": "string","enum": ["list","create","update","stats","set_expiry","revoke","clear_stats"]],"recording": recordingProperty,"video_id": ["type": "string"],"offer_id": ["type": "string"],
                      "title": ["type": "string","description": "Öffentlicher Titel (max. 180 Zeichen)."],"recipient": ["type": "string","description": "Empfänger, z. B. Firma (max. 120)."],
                      "message": ["type": "string","description": "Persönliche Nachricht (max. 1000)."],"booking_url": ["type": "string","description": "HTTPS-Buchungslink; Standard aus den Einstellungen."],
                      "tracking": ["type": "boolean","description": "Wiedergabe-Statistik an/aus."],"tracking_mode": ["type": "string","enum": ["automatic","consent"],"description": "automatic = läuft sofort, Besucher kann abschalten; consent = erst nach Zustimmung."],
                      "sender": ["type": "string","description": "Absender auf der Seite (max. 100)."],"button_title": ["type": "string","description": "Text des Termin-Buttons (1–60)."],
                      "accent": ["type": "string","enum": ["red","blue","violet","green"]],"notify_on_first_open": ["type": "boolean"],
                      "days": ["type": ["integer","null"]],"confirm": confirmProperty],required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        guard ["list","create","update","stats","set_expiry","revoke","clear_stats"].contains(action) else { throw ToolError(message: "Unbekannte Aktion \(action)") }
        var call = pick(args,["video_id","offer_id","title","recipient","message","booking_url","tracking","tracking_mode","sender","button_title","accent","notify_on_first_open","days","confirm"])
        if action == "create", call["video_id"] == nil { call["recording"] = try resolve(args).path }
        if action == "set_expiry", !args.keys.contains("days") { throw ToolError(message: "days angeben (Zahl oder null für dauerhaft).") }
        return [text(try await appCall("offers.\(action)",call,timeout: 180))]
    },
    Tool(name: "meeting_control",description: "Meetings steuern: start (optional title, contact, company; die App fragt vorher nach Bestätigung), stop, discard (laufenden Call verwerfen, confirm), regenerate (Zusammenfassung neu, optional retranscribe), ask (question an einen Call, Antwort aus dem Transkript per Claude), delete (meeting, confirm; Papierkorb).",
         properties: ["action": ["type": "string","enum": ["start","stop","discard","regenerate","ask","delete"]],"meeting": meetingProperty,"title": ["type": "string"],"contact": ["type": "string"],"company": ["type": "string"],
                      "question": ["type": "string"],"retranscribe": ["type": "boolean","description": "Auch das Transkript neu erstellen."],"confirm": confirmProperty],required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        guard ["start","stop","discard","regenerate","ask","delete"].contains(action) else { throw ToolError(message: "Unbekannte Aktion \(action)") }
        var call = pick(args,["title","contact","company","question","retranscribe","confirm"])
        if action == "delete", ((args["meeting"] as? String) ?? "").isEmpty { throw ToolError(message: "meeting zum Löschen ausdrücklich angeben.") }
        if ["regenerate","ask","delete"].contains(action) { call["meeting"] = try resolveMeeting(args["meeting"] as? String).path }
        return [text(try await appCall("meeting.\(action)",call,timeout: action == "start" ? 300 : 180))]
    },
    Tool(name: "guide_control",description: "Anleitungen steuern: start, stop, rewrite (Schritt-Texte neu per Claude), rebuild (Schritte neu aus der Aufnahme), brief (Automatisierungs-Brief, optional frequency_per_week), share (Link erstellen), revoke (Link sperren; ohne confirm nur Vorschau), export_pdf (PDF im Anleitungsordner), delete (confirm; Papierkorb).",
         properties: ["action": ["type": "string","enum": ["start","stop","rewrite","rebuild","brief","share","revoke","export_pdf","delete"]],"guide": guideProperty,
                      "frequency_per_week": ["type": "number","description": "Wie oft der Ablauf pro Woche vorkommt (für den Brief)."],"confirm": confirmProperty],required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        guard ["start","stop","rewrite","rebuild","brief","share","revoke","export_pdf","delete"].contains(action) else { throw ToolError(message: "Unbekannte Aktion \(action)") }
        if action == "export_pdf" {
            let url = try resolveGuide(args["guide"] as? String), guide = try Guide.load(from: url), pdf = url.appendingPathComponent(GuideFile.pdf)
            try GuidePDF.write(guide,directory: url,to: pdf)
            return [text(["pdf": pdf.path,"steps": guide.steps.count])]
        }
        var call = pick(args,["frequency_per_week","confirm"])
        if ["delete","revoke"].contains(action), ((args["guide"] as? String) ?? "").isEmpty { throw ToolError(message: "guide für \(action) ausdrücklich angeben.") }
        if !["start","stop"].contains(action) { call["guide"] = try resolveGuide(args["guide"] as? String).path }
        return [text(try await appCall("guide.\(action)",call,timeout: 300))]
    },
    Tool(name: "edit_guide",description: "Anleitung bearbeiten wie im Editor: title, summary, call_to_action (Knopf „Automatisieren lassen“ auf der geteilten Seite), steps (Liste aus {step, text, note, warning}; step ab 1), add_redactions ({step, x, y, width, height} als Anteil 0–1 des Bildes), remove_redactions ({step, id} aus get_guide), merge_with_next (step), move_step ({from, to}), delete_steps ([step, …]), regenerate_images. Bilder werden bei Strukturänderungen und Schwärzungen neu erzeugt.",
         properties: ["guide": guideProperty,"title": ["type": "string"],"summary": ["type": "string"],"call_to_action": ["type": "boolean"],
                      "steps": ["type": "array","items": ["type": "object","properties": ["step": ["type": "integer"],"text": ["type": "string"],"note": ["type": "string"],"warning": ["type": "string"]]]],
                      "add_redactions": ["type": "array","items": ["type": "object","properties": ["step": ["type": "integer"],"x": ["type": "number"],"y": ["type": "number"],"width": ["type": "number"],"height": ["type": "number"]]]],
                      "remove_redactions": ["type": "array","items": ["type": "object","properties": ["step": ["type": "integer"],"id": ["type": "string"]]]],
                      "merge_with_next": ["type": "integer"],"move_step": ["type": "object","properties": ["from": ["type": "integer"],"to": ["type": "integer"]]],
                      "delete_steps": ["type": "array","items": ["type": "integer"]],"regenerate_images": ["type": "boolean"]],required: []) { args in
        var call = pick(args,["title","summary","call_to_action","steps","add_redactions","remove_redactions","merge_with_next","move_step","delete_steps","regenerate_images"])
        call["guide"] = try resolveGuide(args["guide"] as? String).path
        return [text(try await appCall("guide.edit",call,timeout: 300))]
    },
    Tool(name: "inventory_control",description: "Arbeits-Inventur steuern: start (im Team-Modus nur nach Zustimmung in der App), stop, pause (minutes oder until_tomorrow), resume, exclude (app: Bundle-ID oder App-Name, die nie erfasst wird), analyze (Prozess-Katalog jetzt neu auswerten).",
         properties: ["action": ["type": "string","enum": ["start","stop","pause","resume","exclude","analyze"]],"minutes": ["type": "integer"],"until_tomorrow": ["type": "boolean"],"app": ["type": "string"]],required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        guard ["start","stop","pause","resume","exclude","analyze"].contains(action) else { throw ToolError(message: "Unbekannte Aktion \(action)") }
        return [text(try await appCall("inventory.\(action)",pick(args,["minutes","until_tomorrow","app"]),timeout: action == "start" ? 300 : 60))]
    },
    Tool(name: "storage",description: "Speicher: status (Belegung nach Bereich, freier Platz, Aufräum-Regeln und was die Aufräumung jetzt täte), cleanup (Regeln jetzt anwenden; ohne confirm nur Vorschau). Regeln ändern: settings set mit storage_*.",
         properties: ["action": ["type": "string","enum": ["status","cleanup"]],"confirm": confirmProperty],required: ["action"]) { args in
        let action = args["action"] as? String ?? ""
        guard ["status","cleanup"].contains(action) else { throw ToolError(message: "action: status oder cleanup") }
        return [text(try await appCall("storage.\(action)",pick(args,["confirm"])))]
    },
    Tool(name: "settings",description: "App-Einstellungen lesen (get) oder ändern (set mit values). Schlüssel: share_expiry_days (7|30|90|365|0=nie), Angebots-Vorlage offer_booking_url, offer_message, offer_sender, offer_button_title, offer_accent (red|blue|violet|green), offer_notifications, guide_address (du|sie), hourly_rate, meeting_own_name, meeting_glossary, meeting_show_controller (false = Calls starten als kleiner roter Punkt), launch_at_login, countdown, auto_widescreen, storage_loom_trash_days, storage_studio_archive_days, storage_archive_folder (null = aus), inventory_questions_per_day, inventory_token_budget, inventory_image_days, inventory_sample_days, inventory_catalog_time (HH:MM). Claude-Schlüssel, Share-Server/Token, automatische Meeting-Aufnahme und Team-Inventur bleiben bewusst der App vorbehalten.",
         properties: ["action": ["type": "string","enum": ["get","set"]],"values": ["type": "object","description": "Nur bei set: zu ändernde Schlüssel und Werte."]],required: ["action"]) { args in
        switch args["action"] as? String {
        case "get": return [text(try await appCall("settings.get"))]
        case "set":
            guard let values = args["values"] as? [String: Any], !values.isEmpty else { throw ToolError(message: "values mit mindestens einem Schlüssel angeben.") }
            let allowed: Set<String> = ["share_expiry_days","offer_booking_url","offer_message","offer_sender","offer_button_title","offer_accent","offer_notifications","guide_address","hourly_rate","meeting_own_name","meeting_glossary","meeting_show_controller","launch_at_login",
                                        "countdown","auto_widescreen","storage_loom_trash_days","storage_studio_archive_days","storage_archive_folder",
                                        "inventory_questions_per_day","inventory_token_budget","inventory_image_days","inventory_sample_days","inventory_catalog_time"]
            if let unknown = values.keys.first(where: { !allowed.contains($0) }) { throw ToolError(message: "Unbekannte oder gesperrte Einstellung: \(unknown)") }
            return [text(try await appCall("settings.set",values))]
        default: throw ToolError(message: "action: get oder set")
        }
    },
]
