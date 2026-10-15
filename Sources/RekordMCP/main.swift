import Foundation
import AppKit
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import RecorderCore

// Rekord MCP server (stdio, JSON-RPC 2.0, one message per line).
// Lets Claude Code list, inspect, look at, edit and export recordings with the app's own renderer, and drive the
// running app (open recorder, start/stop/pause, share) through its rekord:// URL scheme.
// Only stdout carries protocol messages; diagnostics go to stderr.

let recordingsFolder = RecordingsFolder.url
// Inside the app bundle the server shares the app's identifier, so the app's defaults are the standard ones.
let appDefaults = Bundle.main.bundleIdentifier == "dev.sapunov.FocusRecorder" ? UserDefaults.standard : UserDefaults(suiteName: "dev.sapunov.FocusRecorder")

struct ToolError: Error { let message: String }

// MARK: Protocol

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object,options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([0x0A]))
}
func log(_ text: String) { FileHandle.standardError.write(Data("[rekord-mcp] \(text)\n".utf8)) }
func text(_ value: Any) -> [String: Any] {
    if let string = value as? String { return ["type": "text","text": string] }
    let data = (try? JSONSerialization.data(withJSONObject: value,options: [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])) ?? Data()
    return ["type": "text","text": String(decoding: data,as: UTF8.self)]
}

// MARK: Recordings

func allRecordings() -> [URL] {
    var urls = (try? FileManager.default.contentsOfDirectory(at: recordingsFolder,includingPropertiesForKeys: [.contentModificationDateKey]))?.filter(ProjectFolder.isProject) ?? []
    for path in appDefaults?.stringArray(forKey: "recentProjects") ?? [] where !urls.contains(where: { $0.path == path }) && ProjectFolder.isProject(URL(fileURLWithPath: path)) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) { urls.append(url) }
    }
    return urls.sorted { modified($0) > modified($1) }
}
func modified(_ url: URL) -> Date { (try? url.appendingPathComponent("project.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
/// Accepts a full path, a folder name, or "latest".
func resolve(_ arguments: [String: Any]) throws -> URL {
    let value = (arguments["recording"] as? String) ?? (arguments["path"] as? String) ?? "latest"
    if value == "latest" { guard let first = allRecordings().first else { throw ToolError(message: "Keine Aufnahmen gefunden.") }; return first }
    let direct = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: direct.appendingPathComponent("project.json").path) { return direct }
    if let match = allRecordings().first(where: { $0.lastPathComponent == value || $0.deletingPathExtension().lastPathComponent == value }) { return match }
    throw ToolError(message: "Aufnahme nicht gefunden: \(value). list_recordings zeigt die verfügbaren Pfade.")
}
/// Version of project.json each tool call started from; `save` only writes if nobody (the app, another MCP
/// server) changed it in between, otherwise the call fails visibly instead of silently replacing their change.
nonisolated(unsafe) var loadedVersions: [String: ProjectVersion] = [:]
func load(_ url: URL) throws -> Project {
    let version = ProjectVersion.current(url)
    let project = try Project.load(from: url)
    loadedVersions[url.standardizedFileURL.path] = version
    return project
}
func save(_ project: Project,to url: URL) throws {
    do { try project.save(to: url,expecting: loadedVersions[url.standardizedFileURL.path]) }
    catch ProjectError.conflict {
        throw ToolError(message: "Die Aufnahme wurde gerade in der App oder einem anderen Prozess geändert. Bitte get_recording erneut aufrufen und die Änderung wiederholen.")
    }
    loadedVersions[url.standardizedFileURL.path] = ProjectVersion.current(url)
}

func summary(_ project: Project,_ url: URL) -> [String: Any] {
    [
        "path": url.path,"title": project.name,"mode": project.recordingMode.rawValue,
        "source": "\(project.width)x\(project.height) @ \(project.fps) fps",
        "duration_s": round2(project.duration),"edited_duration_s": round2(project.editedDuration),
        "zooms": project.zooms.count,"sections": project.cuts.count,
        "camera": project.hasCamera,"microphone": project.hasMicrophone == true,
        "modified": ISO8601DateFormatter().string(from: modified(url)),
    ]
}
func details(_ project: Project,_ url: URL) -> [String: Any] {
    var result = summary(project,url)
    let style = project.style
    result["look"] = [
        "format": style.format.rawValue,"crop": style.crop.map { ["x": round3($0.x),"y": round3($0.y),"width": round3($0.width),"height": round3($0.height)] } as Any,
        "background": style.backdrop.map { "\($0.kind.rawValue)" } ?? style.background.rawValue,
        "padding": round3(style.padding),"corner_radius_px": Int((style.cornerRadius*1080).rounded()),"shadow": round2(style.shadow),
        "motion_blur": round2(style.motionBlur ?? Style.defaultMotionBlur),
        "cursor": ["show": style.showCursor,"size": round2(style.cursorSize),"smoothing_ms": Int(style.smoothing*1000),"tilt": round2(style.cursorTilt ?? Style.defaultCursorTilt),"click_effect": (style.clickEffect ?? .ring).rawValue],
        "camera": ["show": style.showCamera,"shape": (style.cameraShape ?? (project.recordingMode == .loom ? .circle : .rounded)).rawValue,"size": round2(style.cameraSize),
                   "position": ["x": round2(style.cameraPosition.x),"y": round2(style.cameraPosition.y)],"size_while_zoomed": round2(style.cameraZoomScale ?? Style.defaultCameraZoomScale),
                   "border": style.cameraBorder ?? false,"mirror": style.mirrorCamera,"aspect": (style.cameraAspect ?? .square).rawValue],
    ]
    result["zoom_list"] = project.zooms.map { ["id": $0.id.uuidString,"start_s": round2($0.start),"end_s": round2($0.end),"scale": round2($0.scale),"follows_cursor": $0.followsCursor,"focus": ["x": round2($0.focus.x),"y": round2($0.focus.y)]] }
    result["camera_layouts"] = (project.cameraLayouts ?? []).map { ["id": $0.id.uuidString,"layout": $0.layout.rawValue,"start_s": round2($0.start),"end_s": round2($0.end)] }
    result["sections_list"] = project.cuts.map { ["start_s": round2($0.start),"end_s": round2($0.end)] }
    result["clicks_s"] = project.pointer.filter(\.clicked).map { round2($0.time) }
    result["auto_zoom_settings"] = ["scale": project.autoZoom?.scale ?? 2,"lead_s": project.autoZoom?.lead ?? 0.4,"hold_s": project.autoZoom?.hold ?? 1.8]
    return result
}
func round2(_ v: Double) -> Double { (v*100).rounded()/100 }
func round3(_ v: Double) -> Double { (v*1000).rounded()/1000 }

// MARK: Tools

struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let run: ([String: Any]) async throws -> [[String: Any]]
}
let recordingProperty: [String: Any] = ["type": "string","description": "Pfad zur .rekord-Aufnahme, ihr Ordnername oder \"latest\" (Standard)."]

func number(_ arguments: [String: Any],_ key: String) -> Double? {
    guard let value = (arguments[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
    return value
}
/// Whole number from an argument; rejects fractions, non-finite and out-of-range values instead of trapping.
func integer(_ arguments: [String: Any],_ key: String,in range: ClosedRange<Int>) throws -> Int? {
    guard arguments[key] != nil, !(arguments[key] is NSNull) else { return nil }
    guard let value = (arguments[key] as? NSNumber)?.doubleValue, value.isFinite, value.rounded() == value,
          value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
        throw ToolError(message: "\(key) muss eine ganze Zahl zwischen \(range.lowerBound) und \(range.upperBound) sein.")
    }
    return Int(value)
}
func bool(_ arguments: [String: Any],_ key: String) -> Bool? { (arguments[key] as? NSNumber)?.boolValue }

let tools: [Tool] = [
    Tool(name: "list_recordings",description: "Listet alle Rekord-Aufnahmen (neueste zuerst) mit Dauer, Format, Zooms und Abschnitten.",properties: [:],required: []) { _ in
        let items = allRecordings().compactMap { url in (try? load(url)).map { summary($0,url) } }
        return [text(items.isEmpty ? ["hint": "Noch keine Aufnahmen in \(recordingsFolder.path)."] as Any : items)]
    },
    Tool(name: "get_recording",description: "Alle Details einer Aufnahme: Look, Kamera, Cursor, Zooms (mit IDs), behaltene Abschnitte und Klickzeiten.",properties: ["recording": recordingProperty],required: []) { args in
        let url = try resolve(args); return [text(details(try load(url),url))]
    },
    Tool(name: "render_frame",description: "Rendert ein Einzelbild des fertigen Videos (mit Look, Zoom, Cursor, Kamera) als PNG, damit du das Ergebnis ansehen kannst. time_s ist die Zeit im geschnittenen Video.",
         properties: ["recording": recordingProperty,"time_s": ["type": "number","description": "Zeit im geschnittenen Video in Sekunden (Standard 0)."],"height": ["type": "integer","description": "Bildhöhe (kurze Seite), Standard 540."]],required: []) { args in
        let url = try resolve(args); let project = try load(url)
        let edited = min(max(0,number(args,"time_s") ?? 0),project.editedDuration)
        let png = try await renderFrame(project: project,directory: url,editedTime: edited,height: try integer(args,"height",in: 120...2160) ?? 540)
        return [["type": "image","data": png.base64EncodedString(),"mimeType": "image/png"],text("Bild bei \(round2(edited)) s von \(round2(project.editedDuration)) s · \(project.style.format.rawValue)")]
    },
    Tool(name: "update_look",description: "Ändert den Look einer Aufnahme. Nur angegebene Felder werden geändert. Die App lädt offene Projekte automatisch neu.",
         properties: [
            "recording": recordingProperty,
            "format": ["type": "string","enum": CanvasFormat.allCases.map(\.rawValue)],
            "crop": ["type": "string","enum": ["original","16:9-ohne-menuleiste","16:9-mittig"],"description": "Ausschnitt der Aufnahme."],
            "background": ["type": "string","enum": Background.allCases.map(\.rawValue),"description": "Verlauf-Preset."],
            "background_color": ["type": "string","description": "Einfarbiger Hintergrund als Hex, z. B. #1E1E2E."],
            "padding": ["type": "number","description": "Rand 0–0.2 (Anteil der kurzen Bildseite)."],
            "corner_radius_px": ["type": "number","description": "Eckenradius in Pixeln bei 1080p (0–160)."],
            "shadow": ["type": "number","description": "0–1"],
            "motion_blur": ["type": "number","description": "0–1 (0.5 = Standard)"],
            "show_cursor": ["type": "boolean"],"cursor_size": ["type": "number","description": "0.5–3"],"cursor_smoothing_ms": ["type": "number"],"cursor_tilt": ["type": "number","description": "0–1"],
            "click_effect": ["type": "string","enum": ClickEffect.allCases.map(\.rawValue)],
            "show_camera": ["type": "boolean"],"camera_shape": ["type": "string","enum": CameraShape.allCases.map(\.rawValue)],
            "camera_size": ["type": "number","description": "0.1–0.5 der kurzen Bildseite"],
            "camera_position": ["type": "string","enum": ["oben-links","oben-rechts","unten-links","unten-rechts"]],
            "camera_size_while_zoomed": ["type": "number","description": "0.4–1.6 (0.7 = kleiner beim Zoom, >1 = größer)"],
            "camera_border": ["type": "boolean"],"mirror_camera": ["type": "boolean"],
            "camera_aspect": ["type": "string","enum": CameraAspect.allCases.map(\.rawValue),"description": "Proportionen der Kamera (Kreis bleibt rund)."],
            "camera_preset": ["type": "string","enum": CameraPreset.allCases.map(\.rawValue),"description": "Fertiger Kamera-Look: bubble, tile, wide, portrait, polaroid. Wird vor den Einzelwerten angewendet."],
         ],required: []) { args in
        let url = try resolve(args); var p = try load(url)
        if let v = args["camera_preset"] as? String { guard let preset = CameraPreset(rawValue: v) else { throw ToolError(message: "Unbekanntes Kamera-Preset \(v)") }; preset.apply(to: &p.style) }
        if let v = args["camera_aspect"] as? String { guard let aspect = CameraAspect(rawValue: v) else { throw ToolError(message: "Unbekanntes Seitenverhältnis \(v)") }; p.style.cameraAspect = aspect }
        if let v = args["format"] as? String { guard let f = CanvasFormat(rawValue: v) else { throw ToolError(message: "Unbekanntes Format \(v)") }; p.style.format = f }
        if let v = args["crop"] as? String {
            let preset: CropRect.Preset = v == "16:9-ohne-menuleiste" ? .widescreenWithoutMenuBar : (v == "16:9-mittig" ? .widescreenCentered : .original)
            p.style.crop = CropRect.preset(preset,sourceWidth: p.width,sourceHeight: p.height)
        }
        if let v = args["background"] as? String { guard let b = Background(rawValue: v) else { throw ToolError(message: "Unbekannter Hintergrund \(v)") }; p.style.background = b; p.style.backdrop = nil }
        if let hex = args["background_color"] as? String {
            let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")); guard clean.count == 6, let value = Int(clean,radix: 16) else { throw ToolError(message: "Farbe als #RRGGBB angeben") }
            var backdrop = BackdropSettings(kind: .solid); backdrop.start = RGB(Double((value >> 16) & 255)/255,Double((value >> 8) & 255)/255,Double(value & 255)/255); p.style.backdrop = backdrop
        }
        if let v = number(args,"padding") { p.style.padding = v }
        if let v = number(args,"corner_radius_px") { p.style.cornerRadius = v/1080 }
        if let v = number(args,"shadow") { p.style.shadow = v }
        if let v = number(args,"motion_blur") { p.style.motionBlur = v }
        if let v = bool(args,"show_cursor") { p.style.showCursor = v }
        if let v = number(args,"cursor_size") { p.style.cursorSize = v }
        if let v = number(args,"cursor_smoothing_ms") { p.style.smoothing = v/1000 }
        if let v = number(args,"cursor_tilt") { p.style.cursorTilt = v }
        if let v = args["click_effect"] as? String { p.style.clickEffect = ClickEffect(rawValue: v) }
        if let v = bool(args,"show_camera") { p.style.showCamera = v }
        if let v = args["camera_shape"] as? String { p.style.cameraShape = CameraShape(rawValue: v) }
        if let v = number(args,"camera_size") { p.style.cameraSize = v }
        if let v = args["camera_position"] as? String {
            p.style.cameraPosition = ["oben-links": Point(0.16,0.19),"oben-rechts": Point(0.84,0.19),"unten-links": Point(0.16,0.81),"unten-rechts": Point(0.84,0.81)][v] ?? p.style.cameraPosition
        }
        if let v = number(args,"camera_size_while_zoomed") { p.style.cameraZoomScale = v }
        if let v = bool(args,"camera_border") { p.style.cameraBorder = v }
        if let v = bool(args,"mirror_camera") { p.style.mirrorCamera = v }
        do { try save(p,to: url) } catch { throw ToolError(message: "Werte außerhalb des erlaubten Bereichs: \(error.localizedDescription)") }
        return [text(details(p,url)["look"] as Any)]
    },
    Tool(name: "edit_zooms",description: "Zooms bearbeiten. action: clear (alle entfernen), regenerate (aus Klicks neu erzeugen, optional scale/lead_s/hold_s), add (start_s/end_s/scale, optional focus_x/focus_y für festen Punkt), remove (id), update (id + Felder).",
         properties: ["recording": recordingProperty,"action": ["type": "string","enum": ["clear","regenerate","add","remove","update"]],"id": ["type": "string"],
                      "start_s": ["type": "number"],"end_s": ["type": "number"],"scale": ["type": "number","description": "1–4"],"focus_x": ["type": "number"],"focus_y": ["type": "number"],
                      "lead_s": ["type": "number"],"hold_s": ["type": "number"]],required: ["action"]) { args in
        let url = try resolve(args); var p = try load(url)
        switch args["action"] as? String {
        case "clear": p.zooms = []
        case "regenerate":
            let settings = AutoZoomSettings(scale: number(args,"scale") ?? p.autoZoom?.scale ?? 2,lead: number(args,"lead_s") ?? p.autoZoom?.lead ?? 0.4,hold: number(args,"hold_s") ?? p.autoZoom?.hold ?? 1.8)
            guard settings.valid else { throw ToolError(message: "scale 1.25–4, lead_s 0–1.5, hold_s 0.5–5") }
            p.autoZoom = settings; p.zooms = Motion.automaticZooms(pointer: p.pointer,duration: p.duration,settings: settings)
        case "add":
            guard let start = number(args,"start_s"), let end = number(args,"end_s") else { throw ToolError(message: "start_s und end_s angeben (Quellzeit in Sekunden)") }
            var zoom = ZoomSegment(start: start,end: end,scale: number(args,"scale") ?? 2)
            if let x = number(args,"focus_x"), let y = number(args,"focus_y") { zoom.focus = Point(x,y); zoom.followsCursor = false }
            p.zooms.append(zoom); p.zooms.sort { $0.start < $1.start }
        case "remove":
            guard let id = args["id"] as? String, let i = p.zooms.firstIndex(where: { $0.id.uuidString == id }) else { throw ToolError(message: "Zoom-ID nicht gefunden (get_recording zeigt IDs)") }
            p.zooms.remove(at: i)
        case "update":
            guard let id = args["id"] as? String, let i = p.zooms.firstIndex(where: { $0.id.uuidString == id }) else { throw ToolError(message: "Zoom-ID nicht gefunden") }
            if let v = number(args,"start_s") { p.zooms[i].start = v }
            if let v = number(args,"end_s") { p.zooms[i].end = v }
            if let v = number(args,"scale") { p.zooms[i].scale = v }
            if let x = number(args,"focus_x"), let y = number(args,"focus_y") { p.zooms[i].focus = Point(x,y); p.zooms[i].followsCursor = false }
        default: throw ToolError(message: "action: clear, regenerate, add, remove oder update")
        }
        do { try save(p,to: url) } catch { throw ToolError(message: "Ungültige Zoomwerte: \(error.localizedDescription)") }
        return [text(details(p,url)["zoom_list"] as Any)]
    },
    Tool(name: "edit_cuts",description: "Schnitt bearbeiten. action: remove_range (from_s/to_s in Quellzeit herausschneiden), keep_range (nur from_s–to_s behalten), reset (ganze Aufnahme), reset_all_edits (Zooms und Schnitte entfernen).",
         properties: ["recording": recordingProperty,"action": ["type": "string","enum": ["remove_range","keep_range","reset","reset_all_edits"]],"from_s": ["type": "number"],"to_s": ["type": "number"]],required: ["action"]) { args in
        let url = try resolve(args); var p = try load(url)
        switch args["action"] as? String {
        case "reset": p.cuts = [Cut(start: 0,end: p.duration)]
        case "reset_all_edits": p.cuts = [Cut(start: 0,end: p.duration)]; p.zooms = []
        case "keep_range":
            guard let from = number(args,"from_s"), let to = number(args,"to_s"), to > from else { throw ToolError(message: "from_s < to_s angeben") }
            p.cuts = [Cut(start: max(0,from),end: min(p.duration,to))]
        case "remove_range":
            guard let from = number(args,"from_s"), let to = number(args,"to_s"), to > from else { throw ToolError(message: "from_s < to_s angeben") }
            var result: [Cut] = []
            for cut in p.cuts {
                if cut.end <= from || cut.start >= to { result.append(cut); continue }
                if cut.start < from, from-cut.start >= 0.03 { result.append(Cut(start: cut.start,end: from)) }
                if cut.end > to, cut.end-to >= 0.03 { result.append(Cut(start: to,end: cut.end)) }
            }
            guard !result.isEmpty else { throw ToolError(message: "Das würde das ganze Video entfernen.") }
            p.cuts = result
        default: throw ToolError(message: "action: remove_range, keep_range, reset oder reset_all_edits")
        }
        do { try save(p,to: url) } catch { throw ToolError(message: "Ungültiger Schnitt: \(error.localizedDescription)") }
        return [text(["sections": p.cuts.map { ["start_s": round2($0.start),"end_s": round2($0.end)] },"edited_duration_s": round2(p.editedDuration),"zooms": p.zooms.count])]
    },
    Tool(name: "edit_camera_layouts",description: "Kamera-Layouts über die Zeit (Quellzeit): fullscreen (Kamera bildfüllend), split (Bildschirm und Kamera nebeneinander, im Hochformat übereinander), hidden (Kamera aus). Außerhalb dieser Abschnitte schwebt die Kamera normal. action: clear, add (layout, start_s, end_s), remove (id), update (id + Felder). Übergänge sind weich animiert.",
         properties: ["recording": recordingProperty,"action": ["type": "string","enum": ["clear","add","remove","update"]],"layout": ["type": "string","enum": CameraLayout.allCases.map(\.rawValue)],
                      "start_s": ["type": "number"],"end_s": ["type": "number"],"id": ["type": "string"]],required: ["action"]) { args in
        let url = try resolve(args); var p = try load(url)
        guard p.hasCamera else { throw ToolError(message: "Diese Aufnahme hat keine Kamera.") }
        var layouts = p.cameraLayouts ?? []
        switch args["action"] as? String {
        case "clear": layouts = []
        case "add":
            guard let raw = args["layout"] as? String, let layout = CameraLayout(rawValue: raw), let start = number(args,"start_s"), let end = number(args,"end_s") else { throw ToolError(message: "layout, start_s und end_s angeben") }
            layouts.removeAll { $0.start < end && $0.end > start }   // a new layout replaces overlapping ones
            layouts.append(CameraLayoutSegment(start: max(0,start),end: min(p.duration,end),layout: layout))
        case "remove":
            guard let id = args["id"] as? String, let i = layouts.firstIndex(where: { $0.id.uuidString == id }) else { throw ToolError(message: "Layout-ID nicht gefunden (get_recording zeigt IDs)") }
            layouts.remove(at: i)
        case "update":
            guard let id = args["id"] as? String, let i = layouts.firstIndex(where: { $0.id.uuidString == id }) else { throw ToolError(message: "Layout-ID nicht gefunden") }
            if let raw = args["layout"] as? String, let layout = CameraLayout(rawValue: raw) { layouts[i].layout = layout }
            if let v = number(args,"start_s") { layouts[i].start = max(0,v) }
            if let v = number(args,"end_s") { layouts[i].end = min(p.duration,v) }
        default: throw ToolError(message: "action: clear, add, remove oder update")
        }
        p.cameraLayouts = layouts.sorted { $0.start < $1.start }
        do { try save(p,to: url) } catch { throw ToolError(message: "Ungültige Zeiten: \(error.localizedDescription)") }
        return [text(details(p,url)["camera_layouts"] as Any)]
    },
    Tool(name: "rename_recording",description: "Gibt einer Aufnahme einen Titel.",properties: ["recording": recordingProperty,"title": ["type": "string"]],required: ["title"]) { args in
        let url = try resolve(args); var p = try load(url)
        guard let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { throw ToolError(message: "title fehlt") }
        p.name = title; try save(p,to: url); return [text("Titel: \(title)")]
    },
    Tool(name: "export_mp4",description: "Exportiert das fertige Video als MP4 (H.264/AAC) mit dem App-Renderer. Standard: 1080p, Bildrate der Aufnahme, Datei neben der Aufnahme.",
         properties: ["recording": recordingProperty,"output": ["type": "string","description": "Zielpfad .mp4 außerhalb des .rekord-Ordners (optional)"],"overwrite": ["type": "boolean","description": "Vorhandene Zieldatei ersetzen (Standard: nein)"],"height": ["type": "integer","enum": [720,1080,2160]],"fps": ["type": "integer","enum": [30,60]]],required: []) { args in
        let url = try resolve(args); let p = try load(url)
        let height = try integer(args,"height",in: 1...4320) ?? 1080, fps = try integer(args,"fps",in: 1...240) ?? p.defaultExportFPS
        guard [720,1080,2160].contains(height), [30,60].contains(fps) else { throw ToolError(message: "height: 720, 1080 oder 2160 · fps: 30 oder 60") }
        let title = p.name.replacingOccurrences(of: "/",with: "-")
        let output = (args["output"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? url.deletingLastPathComponent().appendingPathComponent("\(title).mp4")
        guard output.pathExtension.lowercased() == "mp4" else { throw ToolError(message: "output muss auf .mp4 enden.") }
        if FileManager.default.fileExists(atPath: output.path), bool(args,"overwrite") != true {
            throw ToolError(message: "\(output.path) existiert bereits. Anderen Pfad wählen oder overwrite: true setzen.")
        }
        try ExportTarget.validate(output,projectDirectory: url)
        let clock = Date()
        try await MovieExporter.export(project: p,directory: url,to: output,height: height,fps: fps)
        return [text(["output": output.path,"duration_s": round2(p.editedDuration),"format": p.style.format.rawValue,"height": height,"fps": fps,"render_s": round2(Date().timeIntervalSince(clock))])]
    },
    Tool(name: "recorder",description: "Steuert die laufende Rekord-App: open (Aufnahmeleiste öffnen), start (optional source: display|area-16:9), stop, pause (Pause/Fortsetzen), show_editor (Aufnahme im Editor öffnen), status. Die App wird bei Bedarf gestartet.",
         properties: ["action": ["type": "string","enum": ["open","start","stop","pause","show_editor","status"]],"source": ["type": "string","enum": ["display","area-16:9"]],"recording": recordingProperty],required: ["action"]) { args in
        let action = args["action"] as? String ?? "status"
        if action == "status" { return [text(appStatus())] }
        var components = URLComponents(); components.scheme = "rekord"; components.host = action == "show_editor" ? "open" : action
        if action == "start", let source = args["source"] as? String { components.queryItems = [URLQueryItem(name: "source",value: source)] }
        if action == "show_editor" { components.queryItems = [URLQueryItem(name: "path",value: try resolve(args).path)] }
        guard let url = components.url else { throw ToolError(message: "Ungültige Aktion") }
        try openInApp(url)
        try await Task.sleep(nanoseconds: action == "start" ? 4_500_000_000 : 1_200_000_000)
        return [text(appStatus())]
    },
    Tool(name: "share_link",description: "Erstellt über die App einen öffentlichen Link zur Aufnahme (benötigt den eingerichteten Share-Server) und gibt die URL zurück.",properties: ["recording": recordingProperty],required: []) { args in
        let url = try resolve(args)
        let receipt = url.appendingPathComponent("share.json")
        let before = (try? receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let job = UUID().uuidString
        var components = URLComponents(); components.scheme = "rekord"; components.host = "share"; components.queryItems = [URLQueryItem(name: "path",value: url.path),URLQueryItem(name: "id",value: job)]
        try openInApp(components.url!)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            // The app acknowledges the job in status.json: errors come back at once instead of after the timeout.
            if let result = appStatus()["last_command"] as? [String: Any], result["id"] as? String == job {
                if result["ok"] as? Bool == false { throw ToolError(message: "Rekord hat die Freigabe abgelehnt: \(result["error"] as? String ?? "unbekannter Fehler")") }
                if let link = result["link"] as? String { return [text(["url": link])] }
            }
            let now = (try? receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now > before, let data = try? Data(contentsOf: receipt), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let video = json["video"] as? [String: Any], let link = video["url"] as? String { return [text(["url": link])] }
        }
        throw ToolError(message: "Kein Link innerhalb von 5 Minuten. Ist der Share-Server in der App eingerichtet?")
    },
    Tool(name: "list_meetings",description: "Listet aufgenommene Meetings (Calls), neueste zuerst: Gesprächspartner, Firma, Datum, Dauer, Interesse 1–5, Kurzfassung und nächster Schritt. Filter optional, z. B. min_interest 4 für heiße Leads.",
         properties: ["min_interest": ["type": "integer","description": "Nur Meetings mit Interesse ≥ diesem Wert (1–5)."],
                      "since": ["type": "string","description": "Nur Meetings ab diesem Datum (YYYY-MM-DD)."],
                      "query": ["type": "string","description": "Suchtext in Titel, Gesprächspartner und Firma."]],required: []) { args in
        let minimum = try integer(args,"min_interest",in: 0...5) ?? 0
        let since = (args["since"] as? String).flatMap { value -> Date? in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: value) }
        let query = (args["query"] as? String ?? "").lowercased()
        let items: [[String: Any]] = MeetingsFolder.all().compactMap { url in
            guard let meeting = try? Meeting.load(from: url) else { return nil }
            let summary = try? MeetingSummary.load(from: url)
            if minimum > 0, (summary?.interest ?? 0) < minimum { return nil }
            if let since, meeting.startedAt < since { return nil }
            if !query.isEmpty, ![meeting.title,meeting.contact,meeting.company,summary?.company ?? "",summary?.contact ?? ""].joined(separator: " ").lowercased().contains(query) { return nil }
            return meetingSummary(meeting,summary,url)
        }
        return [text(items.isEmpty ? ["hint": "Keine passenden Meetings in \(MeetingsFolder.url.path)."] as Any : items)]
    },
    Tool(name: "get_meeting",description: "Ein Meeting komplett: Metadaten, strukturierte Sales-Zusammenfassung (Schmerz, Budget, Entscheider, Einwände wörtlich, Interesse, nächster Schritt, Follow-up-Entwurf) und das Transkript mit Sprechern und Zeitstempeln.",
         properties: ["meeting": ["type": "string","description": "Pfad oder Ordnername aus list_meetings. Ohne Angabe: das neueste Meeting."],
                      "include_transcript": ["type": "boolean","description": "Transkript mitliefern (Standard true)."]],required: []) { args in
        let url = try resolveMeeting(args["meeting"] as? String)
        let meeting = try Meeting.load(from: url)
        let summary = try? MeetingSummary.load(from: url)
        var result = meetingSummary(meeting,summary,url)
        result["error"] = meeting.error as Any
        if let summary { result["summary"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))) as Any; result["summary_markdown"] = summary.markdown(for: meeting) }
        if bool(args,"include_transcript") ?? true, let transcript = try? Transcript.load(from: url) { result["transcript_markdown"] = transcript.markdown(for: meeting) }
        return [text(result)]
    },
    Tool(name: "list_guides",description: "Listet Anleitungen (Schritt-für-Schritt aus Bildschirmaufnahmen), neueste zuerst: Titel, Apps, Schrittzahl, ob ein Automatisierungs-Brief und ein geteilter Link existieren.",
         properties: ["query": ["type": "string","description": "Suchtext in Titel und App-Namen."]],required: []) { args in
        let query = (args["query"] as? String ?? "").lowercased()
        let items: [[String: Any]] = GuidesFolder.all().compactMap { url in
            guard let guide = try? Guide.load(from: url) else { return nil }
            if !query.isEmpty, !([guide.title]+guide.apps).joined(separator: " ").lowercased().contains(query) { return nil }
            return guideSummary(guide,url)
        }
        return [text(items.isEmpty ? ["hint": "Keine Anleitungen in \(GuidesFolder.url.path)."] as Any : items)]
    },
    Tool(name: "get_guide",description: "Eine Anleitung komplett: guide.json (Schema rekord.guide, pro Schritt Aktion, Text, Element mit Rolle und Beschriftung, App, URL, Zeit im Video, Bildpfad, Schwärzungen), Markdown, absolute Bildpfade und, falls vorhanden, der Automatisierungs-Brief. Grundlage für Automatisierungs-Entwürfe (z. B. n8n).",
         properties: ["guide": ["type": "string","description": "Pfad oder Ordnername aus list_guides. Ohne Angabe: die neueste Anleitung."],
                      "include_images": ["type": "boolean","description": "Schritt-Bilder (geschwärzt) zusätzlich als Bilder mitliefern (Standard false, nur Pfade)."]],required: []) { args in
        let url = try resolveGuide(args["guide"] as? String)
        let guide = try Guide.load(from: url)
        var result = guideSummary(guide,url)
        result["guide_json"] = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(GuideFile.guide)))) as Any
        result["markdown"] = guide.markdown()
        result["images"] = guide.steps.compactMap { $0.image.map { url.appendingPathComponent($0).path } }
        result["video"] = url.appendingPathComponent(guide.video).path
        if let brief = try? AutomationBrief.load(from: url) {
            result["automation_brief"] = (try? JSONSerialization.jsonObject(with: Guide.encoder.encode(brief))) as Any
            result["automation_brief_markdown"] = brief.markdown()
        }
        var content: [[String: Any]] = [text(result)]
        if bool(args,"include_images") ?? false {
            for step in guide.steps.prefix(30) {
                if let image = step.image, let data = try? Data(contentsOf: url.appendingPathComponent(image)) { content.append(["type": "image","data": data.base64EncodedString(),"mimeType": "image/jpeg"]) }
            }
        }
        return content
    },
]

func guideSummary(_ guide: Guide,_ url: URL) -> [String: Any] {
    ["guide": url.path,"title": guide.title,"apps": guide.apps,"steps": guide.steps.count,"duration_s": round2(guide.duration),
     "created_at": ISO8601DateFormatter().string(from: guide.createdAt),"texts_by": guide.textsBy,
     "has_automation_brief": FileManager.default.fileExists(atPath: url.appendingPathComponent(GuideFile.brief).path),
     "shared_url": GuideSharing.record(in: url)?.url.absoluteString as Any]
}
func resolveGuide(_ value: String?) throws -> URL {
    let all = GuidesFolder.all()
    guard let value, !value.isEmpty else { guard let newest = all.first else { throw ToolError(message: "Noch keine Anleitungen aufgenommen.") }; return newest }
    let direct = URL(fileURLWithPath: value)
    if GuidesFolder.isGuide(direct) { return direct }
    if let match = all.first(where: { $0.lastPathComponent == value || $0.lastPathComponent.localizedCaseInsensitiveContains(value) }) { return match }
    throw ToolError(message: "Anleitung \(value) nicht gefunden. list_guides zeigt alle.")
}

func meetingSummary(_ meeting: Meeting,_ summary: MeetingSummary?,_ url: URL) -> [String: Any] {
    var item: [String: Any] = ["meeting": url.path,"title": meeting.displayTitle,"contact": meeting.contact,"company": meeting.company,
                               "started_at": ISO8601DateFormatter().string(from: meeting.startedAt),"duration_s": round2(meeting.duration),
                               "consent": meeting.consent,"has_system_audio": meeting.hasSystemAudio,"status": meeting.status.rawValue]
    if let summary {
        item["interest"] = summary.interest; item["short_summary"] = summary.shortSummary
        item["next_step"] = ["action": summary.nextStep.action,"date": summary.nextStep.date,"owner": summary.nextStep.owner]
    }
    return item
}
func resolveMeeting(_ value: String?) throws -> URL {
    let all = MeetingsFolder.all()
    guard let value, !value.isEmpty else { guard let newest = all.first else { throw ToolError(message: "Noch keine Meetings aufgenommen.") }; return newest }
    let direct = URL(fileURLWithPath: value)
    if MeetingsFolder.isMeeting(direct) { return direct }
    if let match = all.first(where: { $0.lastPathComponent == value || $0.lastPathComponent.localizedCaseInsensitiveContains(value) }) { return match }
    throw ToolError(message: "Meeting \(value) nicht gefunden. list_meetings zeigt alle.")
}

func appStatus() -> [String: Any] {
    let file = SupportFolder.url.appendingPathComponent("status.json")
    guard let data = try? Data(contentsOf: file), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["running": false] }
    json["running"] = !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.sapunov.FocusRecorder").isEmpty
    return json
}
func openInApp(_ url: URL) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-g",url.absoluteString]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToolError(message: "Rekord konnte nicht angesprochen werden. Ist die App installiert?") }
}

func renderFrame(project: Project,directory: URL,editedTime: Double,height: Int) async throws -> Data {
    let source = project.sourceTime(at: editedTime)
    let screen = try await VideoFrames(url: directory.appendingPathComponent("screen.mov"))
    let renderer = FrameRenderer(project: project,backgroundImage: try BackgroundAsset.load(project: project,directory: directory))
    guard let buffer = try screen.buffer(at: source), let screenImage = renderer.cgImage(from: buffer) else { throw ToolError(message: "Bild bei \(source) s nicht lesbar") }
    var cameraImage: CGImage?
    if project.hasCamera, project.style.showCamera, source >= project.cameraOffset {
        let camera = try await VideoFrames(url: directory.appendingPathComponent("camera.mov"))
        if let frame = try camera.buffer(at: source-project.cameraOffset) { cameraImage = renderer.cgImage(from: frame) }
    }
    let (w,h) = project.style.format.dimensions(height: min(1080,max(240,height)))
    guard let image = renderer.image(screen: screenImage,camera: cameraImage,time: source,width: w,height: h) else { throw ToolError(message: "Rendern fehlgeschlagen") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw ToolError(message: "PNG fehlgeschlagen") }
    CGImageDestinationAddImage(destination,image,nil); CGImageDestinationFinalize(destination)
    return data as Data
}

// MARK: Loop

func handle(_ message: [String: Any]) async {
    let id = message["id"]
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]
    func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0","id": id,"result": result]) } }
    func fail(_ code: Int,_ text: String) { if let id { send(["jsonrpc": "2.0","id": id,"error": ["code": code,"message": text]]) } }
    switch method {
    case "initialize":
        reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18","capabilities": ["tools": ["listChanged": false]],
               "serverInfo": ["name": "rekord","version": "1.7.0"],
               "instructions": "Rekord: Bildschirmaufnahmen mit Auto-Zoom, Kamera und Hintergrund. Typischer Ablauf: list_recordings → get_recording → render_frame zum Ansehen → update_look / edit_zooms / edit_cuts → render_frame zur Kontrolle → export_mp4 oder share_link. recorder startet und stoppt Aufnahmen in der App. Meetings (Calls mit Transkript und Sales-Zusammenfassung): list_meetings → get_meeting. Anleitungen (Schritt-für-Schritt aus Klicks, mit Automatisierungs-Brief): list_guides → get_guide. Zeiten in edit_zooms/edit_cuts sind Quellzeit, in render_frame die Zeit im geschnittenen Video."])
    case "notifications/initialized","notifications/cancelled": break
    case "ping": reply([:])
    case "tools/list":
        reply(["tools": tools.map { ["name": $0.name,"description": $0.description,"inputSchema": ["type": "object","properties": $0.properties,"required": $0.required]] }])
    case "tools/call":
        guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else { fail(-32602,"Unbekanntes Werkzeug"); return }
        do { reply(["content": try await tool.run(params["arguments"] as? [String: Any] ?? [:]),"isError": false]) }
        catch let error as ToolError { reply(["content": [text(error.message)],"isError": true]) }
        catch { reply(["content": [text(error.localizedDescription)],"isError": true]) }
    default: if id != nil { fail(-32601,"Methode nicht unterstützt: \(method)") }
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    await handle(message)
}
