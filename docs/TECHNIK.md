# Rekord – Technik

Technische Referenz: Aufbau, Modi im Detail, Speicher, Tests und Struktur. Zurück zum [README](../README.md).

## Features

- **Aufnahme:** ganzer Bildschirm, Fenster oder Bereich, dazu Kamera, Mikrofon und Systemton. Schwebende Glas-Toolbar, Kamera-Bubble und Aufnahme-Pille mit Pause, Neustart und Verwerfen.
- **MacBook → 16:9 automatisch:** Bei MacBook-Displays (1,54:1 bzw. 16:10) werden Menüleiste und Dock weggeschnitten. Das Video füllt 16:9 randlos.
- **Auto-Zoom:** Zooms auf jeden Klick, die dem Cursor folgen, auf einer kritisch gedämpften Feder (schneller Start, weiche Landung, kein Überschwingen), mit GPU-Motion-Blur.
- **Kamera:** Stile (Bubble, Kachel, Breit, Hochkant, Polaroid), Formen, Seitenverhältnisse. Dazu Layouts über die Zeit: Vollbild, Geteilt (Bildschirm und Kamera nebeneinander), Ausgeblendet.
- **Studio-Hintergründe:** zwölf prozedural gerenderte Wallpaper mit weichem Licht und feinem Film Grain, keine Farbstufen (Banding) nach dem YouTube-Encoding.
- **Editor:** Filmstreifen-Timeline mit Spuren für Schnitt, Zoom und Kamera, Echtzeit-Preview (identisch mit dem Export), Undo/Redo, „Alle Edits entfernen“.
- **Export:** MP4 in 1080p oder 4K, 30 oder 60 fps, in einer Export-Queue im Hintergrund. Formate 16:9, 9:16, 1:1, 4:5.
- **Loom-Modus:** Die Komposition läuft schon während der Aufnahme auf der GPU. Nach dem Stoppen wird hochgeladen, und der Link liegt in der Zwischenablage.
- **Meeting-Modus (Call-Notizen):** erkennt Calls in Google Meet, Zoom, Teams, FaceTime, Slack und weiteren Apps und nimmt sie nach ausdrücklich aktiviertem Opt-in automatisch auf, mit eigenem Mikrofon und Gegenseite als getrennten Spuren. Nach dem Call: lokales Transkript und eine deutsche Sales-Zusammenfassung (Interesse 1–5, wörtliche Einwände, nächster Schritt, Follow-up-Entwurf). Details unten.
- **Anleitungs-Modus:** Ablauf am Bildschirm aufnehmen und dabei erklären. Rekord macht daraus eine Schritt-für-Schritt-Anleitung (ein Schritt pro Klick, Screenshot mit markierter Stelle, kurzer Text), schwärzt E-Mail, IBAN, Telefon und Passwörter, und gibt sie als Web-Seite, PDF, Markdown und `guide.json` aus. Dazu ein Automatisierungs-Brief: welche Schritte sich wie automatisieren lassen und was das an Zeit spart. Details unten.
- **MCP für Claude Code:** Aufnahmen auflisten, ansehen (`render_frame`), Look, Zooms, Schnitte und Kamera-Layouts bearbeiten, exportieren, teilen und Aufnahmen starten oder stoppen.

## Aus dem Quellcode bauen

Build: Xcode 26+ und macOS SDK 26+. Laufzeit: Studio ab macOS 14, Meeting-Systemton ab 14.2, lokale Transkription ab 26. Siehe [Voraussetzungen und Kosten](../README.md#voraussetzungen-und-kosten).

```sh
./scripts/install.sh    # bauen, nach ~/Applications installieren, MCP in Claude Code registrieren, starten
./scripts/update.sh     # git pull --ff-only, danach install.sh
./scripts/build-app.sh  # nur bauen und installieren
./scripts/release.sh --package /tmp/rekord-release-review  # signiert/notarisiert, noch kein Upload
./scripts/release.sh --publish /tmp/rekord-release-review  # nach Prüfung veröffentlichen
```

- Die App liegt immer unter `~/Applications/Rekord.app`. Den Ordner änderst du mit `REKORD_APP_DIR`.
- Sie liegt bewusst außerhalb von iCloud Documents, weil der File Provider Finder-Metadaten an signierte Bundles hängt und die Signatur damit kaputtmacht.
- **Signatur:** `scripts/signing-identity.sh` legt beim ersten Build eine selbstsignierte, lokale Signing-Identity an. Sie liegt in einer eigenen Keychain unter `~/Library/Application Support/Rekord/signing`. Dadurch bleiben die macOS-Freigaben (Bildschirm, Kamera, Mikrofon) über Rebuilds hinweg erhalten.
- Das ist keine Distributions-Signatur. Der Distributionsmodus `REKORD_SIGNING=distribution` verlangt Developer ID. Paketbau verlangt anschließend Notarisierung; siehe [Release-Ablauf](RELEASE.md). `REKORD_SIGNING=adhoc` signiert stattdessen ad hoc pro Build (dann gehen die Freigaben nach Code-Änderungen verloren).
- Die App umgeht TCC nicht.

## Claude Code (MCP)

Im Bundle steckt der MCP-Server `rekord-mcp`. `install.sh` registriert ihn in Claude Code im User-Scope als `rekord`.

- Bearbeiten, Ansehen und Exportieren laufen direkt mit dem Renderer der App. Die App muss dafür nicht offen sein.
- Aufnahme-Steuerung und Teilen laufen über das URL-Schema `rekord://` an die laufende App.
- Alle Werkzeuge und Beispiele: [docs/MCP.md](MCP.md).

## Meeting-Modus (Call-Notizen)

Ein Notetaker für Sales-Calls, in der App statt in der Cloud. Er läuft ohne Bot, der dem Meeting beitritt, wie Fathoms Desktop-App.

1. **Automatisch (standardmäßig aus):** Nach Aktivierung samt Aufnahmehinweis in den Einstellungen: Sobald eine Meeting-App das Mikrofon benutzt, startet Rekord nach etwa 6 Sekunden die Aufnahme. Bei Browsern muss zusätzlich ein Fenstertitel ein Meeting zeigen (Google Meet, Teams, Zoom im Web).
   - Erkannt werden Zoom, Teams, Slack Huddles, FaceTime und Anrufe vom iPhone, Webex, Discord, WhatsApp und Telegram, dazu Chrome, Safari, Arc, Edge, Brave, Firefox und weitere Browser.
   - Gibt die App das Mikrofon frei, also wenn der Call endet, stoppt Rekord nach rund 6 Sekunden. Danach kommt die Mitteilung „Transkript fertig“; ein Klick öffnet das Meeting.
   - Von Hand geht es auch: Seitenleiste **Meetings** → **Meeting aufnehmen** oder **⌃⌥⌘M** (bewusst nicht ⌘⇧M: das ist in Teams die Stummschaltung und in Zoom das Mini-Fenster).
   - Im schwebenden Controller verwirft der Papierkorb eine Fehlauslösung, und dieser Call wird nicht erneut aufgenommen.
   - Start beim Anmelden wird bei Bedarf in den Einstellungen aktiviert. Frühere gespeicherte Automatik-Einstellungen werden beim Sicherheitsupdate einmalig deaktiviert; eine bewusste neue Aktivierung ist nötig.
   - Informiere die Beteiligten und kläre ihre Zustimmung vorher. Die App speichert nur deine Bestätigung des Aufnahmehinweises, keinen Nachweis ihrer Zustimmung.
2. **Aufnahme:** `microphone.m4a` (deine Stimme) und `system.m4a` (Gegenseite) als getrennte Spuren auf einer Zeitachse.
   - Der Systemton läuft über einen eigenen Core-Audio-Process-Tap (macOS 14.2+, Freigabe „Nur Systemaudio“). Er nimmt alles auf außer Rekord und Musik-Playern (Spotify, Musik, Podcasts, VLC …). Zoom, Meet im Browser, Teams, FaceTime und „Anrufe vom iPhone“ laufen also mit, Hintergrundmusik nicht.
   - Ein schwebender Controller zeigt App, Zeit, beide Pegel, Stopp und Verwerfen.
3. **Transkript lokal:** Apples `SpeechTranscriber` auf dem Mac (macOS 26). Sprecher-Labels kommen aus der Spur: Mikrofon = du, Systemton = Gesprächspartner.
   - Ohne Kopfhörer hört das Mikrofon die Gegenseite aus dem Lautsprecher mit. Solche Echo-Sätze erkennt Rekord und entfernt sie.
   - Gemessen am 15.10.2026: 10 Minuten Call, beide Spuren, inklusive Zusammenfassung in 12,7 s. whisper.cpp large-v3 bräuchte pro Spur über 4 Minuten, kannte Eigennamen aber etwas besser.
4. **Zusammenfassung:** Claude API (`claude-sonnet-5-5`, strukturierte JSON-Ausgabe), eigene deutsche Sales-Vorlage:
   - Firma, Gesprächspartner, Ausgangslage, größter Schmerz, aktueller Prozess, Budget-Signal, Entscheider
   - Einwände wörtlich mit Zeitstempel, Interesse 1–5, nächster Schritt mit Datum, Aufgaben, Follow-up-Entwurf
   - Nur Fakten aus dem Transkript. Lücken heißen „nicht angesprochen“.
   - Der Schlüssel liegt im Schlüsselbund und wird in den Einstellungen eingetragen (Zahnrad in der Seitenleiste oder bei Meetings).
   - Dort stehen auch dein Name im Transkript und eine Begriffsliste, mit der Claude verhörte Firmen- und Produktnamen korrigiert.

**Datenschutz:** Ton und Transkript bleiben auf dem Mac. Nur Transkripttext, Titel, Name und Firma gehen zur Zusammenfassung an die Anthropic-API. Geprüft im Abnahmelauf: Außer einer HTTPS-Verbindung zu `api.anthropic.com` öffnet Rekord keine Verbindung.

**Ablage:** `~/Movies/Rekord/Meetings/<Datum Titel>/` mit `meeting.json`, `microphone.m4a`, `system.m4a`, `transcript.json`/`.md` und `summary.json`/`.md`. In der App gibt es Liste, Zusammenfassung, Transkript, „Follow-up kopieren“, „Notiz kopieren“ sowie „Neu zusammenfassen“ und „Neu transkribieren“. Claude Code fragt per MCP ab (`list_meetings`, `get_meeting`), zum Beispiel: „Wer hatte heute Interesse ≥ 4?“

Befehle: `rekord://meetings` (Bereich öffnen), `rekord://meeting` (Aufnahme starten), `rekord://meeting-stop`. Eine automatisch gestartete Aufnahme ganz ohne Ton (Fehlauslösung, gesperrter Bildschirm) wird verworfen. Übernommen sind nur Erkenntnisse, kein Code und kein Text von Fathom.

## Anleitungs-Modus (Schritt-für-Schritt-Anleitungen)

Für Unternehmer: einen Ablauf einmal vormachen und erklären („So legen wir eine Rechnung an“), Rekord schreibt die Anleitung. Seitenleiste **Anleitungen** → **Anleitung aufnehmen**. Aufgenommen werden der Bildschirm unter dem Mauszeiger und das Mikrofon, keine Kamera. Ein schwebender Controller zeigt Zeit, erfasste Klicks und **Anleitung fertig**.

1. **Klick → Element:** Im Moment jedes Klicks liest Rekord über die Bedienungshilfen-API (`AXUIElementCopyElementAtPosition`) das Element darunter: Rolle, Titel, Beschriftung, Platzhalter, App, Fenster und bei Browsern die URL (ohne Query). So entsteht „Klicke auf ‚Neue Rechnung‘“ statt „Klicke hier“, in nativen Apps, im Browser und in Electron-Apps (`AXManualAccessibility`). Braucht einmalig das Recht unter **Datenschutz & Sicherheit → Bedienungshilfen**. Ohne das Recht gibt es Schritte, aber ohne Elementnamen.
2. **Tippen ohne Keylogger:** Kein Tastatur-Mitschnitt. Rekord merkt sich nur, ob sich ein Textfeld beim Verlassen geändert hat (Zeichenzahl). Der getippte Text wird nie gelesen oder gespeichert. Passwortfelder (`AXSecureTextField`) werden nie ausgelesen.
3. **Schritte bilden:** zwei Klicks unter 0,5 s und an derselben Stelle = Doppelklick, Klicks auf dasselbe Element innerhalb von 2 s = ein Schritt, Klicks auf Seiten- und Fensterflächen = kein Schritt, Klick in ein Feld + Tippen = ein Schritt „eintragen“, Klicks auf Rekord selbst zählen nicht.
4. **Screenshot kurz vor dem Klick** (0,15 s) aus dem Video, also mit dem Zustand, den du gesehen hast (auch Hover-Menüs). Klick-Ring und Rahmen um das Element.
5. **Schwärzen lokal:** Apples Texterkennung (Vision) findet E-Mail-Adressen, IBANs, Telefonnummern, Kartennummern (Luhn-Prüfung) und Passwort-Punkte und deckt sie deckend ab. Dazu manuelles Schwärzen im Editor. Gespeichert wird nur das geschwärzte Bild, neu erzeugt aus dem Video.
6. **Texte:** Lokales Transkript (SpeechTranscriber), Sätze werden dem Klick zugeordnet, bei dem sie fallen. Claude (`claude-sonnet-5-5`, strukturiert) schreibt daraus Titel, Schritt-Texte und Tipps/Warnungen nur aus dem Gesagten, Anrede Du oder Sie. Ohne Claude-Schlüssel stehen Vorlagen-Texte da („Klicke auf die Schaltfläche ‚Speichern‘.“).
7. **Editor:** Titel, Texte und Tipps bearbeiten, Schritte verschieben, zusammenlegen, löschen, Bereiche schwärzen.
8. **Ausgabe:** `guide.json` (Schema `rekord.guide`, Version 1; Felder kommen nur dazu, werden nie umbenannt), `guide.md` mit Bildern, PDF, und **Teilen** als mobile Seite auf dem eigenen Share-Server (nur Texte, aktuelle geschwärzte Schritt-Bilder und optional Brief).
9. **Automatisierungs-Brief:** „Wie oft pro Woche?“ eintragen, **Brief erstellen**. Claude ordnet die Schritte zu Gruppen: automatisierbar ja/teilweise/nein, womit (offizielle API, n8n, Trigger.dev, Claude-Code-Skript, Browser-Agent, Mensch), Aufwand. Ob eine App eine API hat, steht nur dann als „bekannt“ da, wenn es sicher ist, sonst „prüfen“. Die Zeitersparnis rechnet Rekord selbst aus Schrittdauern, Häufigkeit und Stundensatz. Auf der geteilten Seite steht eine Kurzfassung plus der Knopf „Diesen Ablauf automatisieren lassen“ (im ⋯-Menü pro Anleitung abschaltbar).
10. **An Claude Code:** kopiert einen fertigen Auftrag in die Zwischenablage. Er verweist auf `get_guide` und den Brief und baut einen **inaktiven** n8n-Entwurf (über den n8n-MCP, sonst als `n8n-workflow.json` im Anleitungsordner).

**Was den Mac verlässt:** Ohne ausdrückliche Aktion nichts. Für die Texte und den Brief gehen nur Text-Daten an die Anthropic-API: Elementnamen und Rollen, App-Namen, Fenstertitel und URLs ohne Query (E-Mail, IBAN, Telefon, Karte vorher maskiert) und das maskierte Transkript. Keine Screenshots, kein Ton, keine getippten Werte (die gibt es gar nicht). Beim Teilen gehen die aktuellen geschwärzten Schritt-Bilder, Texte, App-Namen, stabile Anleitungs-ID und optional der Brief an deinen eigenen Share-Server. Rohvideo und Ton bleiben lokal. Der Server muss `guide-lifecycle-v2` unterstützen. Widerruf sperrt alle verbundenen Fassungen und alte Video-Verknüpfungen.

**Ablage:** `~/Movies/Rekord/Anleitungen/<Datum Titel>/` mit `project.json`, `screen.mov`, `microphone.m4a` (öffnet auch als Video-Projekt), `steps.json` (Roh-Klicks), `transcript.json`, `guide.json`, `guide.md`, `images/`, optional `guide.pdf`, `automation-brief.json`/`.md`, `share.json`.

Befehle: `rekord://guides`, `rekord://guide` (startet die Aufnahme), `rekord://guide-stop`. MCP: `list_guides`, `get_guide`. Abnahme-Läufe: `--guide-check <dir> --scenario web|chrome|native|electron` (live, braucht Bedienungshilfen), `--guide-replay <dir> [--image page.png]` (alles nach der Klick-Erfassung, ohne Bedienungshilfen). Übernommen sind nur Erkenntnisse, kein Code, kein Asset und kein Text von Scribe oder Tango.

## Zwei Aufnahme-Modi

**Studio**
- Für YouTube und Erklärvideos: automatische Klick-Zooms, Hintergrund, Rahmen und der volle Editor.
- 30 oder 60 fps.

**Loom**
- Schlichte Aufnahme mit runder Kamera und Mikrofon, 30 fps.
- Nach dem Stoppen wird automatisch hochgeladen, und der Abspiel-Link landet in der Zwischenablage.
- Ein unverändertes Loom-Video wird nicht noch einmal Frame für Frame gerendert.

Beide Modi behalten die Original-Spuren (Bildschirm, Kamera, Cursor, Audio). Du kannst also jederzeit nachbearbeiten.

**Teilen** läuft über einen eigenen Share-Server, siehe [share-service/README.md](../share-service/README.md).
- **Einrichten:** einmal unter **Share-Server einrichten** die URL und den Upload-Token eintragen, oder eine private JSON-Verbindungsdatei über **Verbindung importieren …** laden.
- **Speicherort des Tokens:** Er liegt in der macOS Keychain (Eintrag `dev.sapunov.Rekord.share`). Er wird pro App-Start einmal gelesen.
- **Ohne eingerichteten Server** bleibt die Aufnahme lokal. Es wird nie stillschweigend bei einem fremden Anbieter hochgeladen.
- **Link teilen** teilt einen Studio-Export oder wiederholt einen fehlgeschlagenen Upload. Das vorbereitete MP4 wird über den Content-Fingerprint des Projekts gecacht. Ein erneuter Upload derselben Datei liefert denselben Link.
- **Share-Server verwalten → Freigaben verwalten** widerruft ältere Links.

Den Share-Server betreibst du selbst (Docker oder Node 22, Anleitung in [share-service/README.md](../share-service/README.md)). Ohne Server funktioniert alles andere lokal.

## Aufnehmen

1. **Neue Aufnahme** (`⌘⇧1`) öffnet den Recorder: Glas-Toolbar unten am Bildschirm und Kamera-Bubble.
2. Quelle wählen: **Bildschirm**, **Fenster** oder **Bereich**. Die Auswahl passiert direkt auf dem Bildschirm, ein 16:9-Bereich ist vorbereitet.
3. Optional Kamera, Mikrofon und Systemton einschalten und das Gerät wählen. „Systemstandard“ folgt macOS, die Wahl wird gemerkt. Im **⋯-Menü** stehen Bildrate (30/60 fps), Videoformat, Countdown und der automatische 16:9-Zuschnitt.
4. **Starten.**
   - Die Aufnahme-Pille zeigt die Zeit und hat Pause, Neustart und Verwerfen.
   - `⌘⇧2` stoppt, `⌘⇧P` pausiert und setzt fort, `Esc` bricht den Countdown ab bzw. schließt den Recorder.
   - Die Kürzel arbeiten als Carbon-Hotkeys, also ohne Accessibility-Freigabe.
   - Die Fenster der App selbst sind nie mit im Bild.
5. **Stopp** öffnet den Editor.
   - Pausen werden automatisch zu Schnitten.
   - Die Tonspuren bekommen während der Pause Stille, damit Bild und Ton synchron bleiben.
6. Das Projekt liegt unter `~/Movies/Rekord/<Name>.rekord`: `project.json`, `screen.mov`, optional `camera.mov` und `microphone.m4a`. Den Ordner immer komplett zusammenhalten. Eigene Ordner (eine Ebene, z. B. `~/Movies/Rekord/Kunden/`) sind die Ordner der Bibliothek. `Meetings`, `Anleitungen` und `Inventur` sind reserviert.

**Technische Details der Aufnahme**
- **Video:** H.264 mit hoher Bitrate in Retina-Auflösung, maximal 4096 px an der langen Kante, in sRGB, jede Datei ist als BT.709 getaggt.
- **Cursor:** Der echte Cursor wird ausgeblendet und aus aufgezeichneten Bewegungsdaten neu gezeichnet. Aktuell gibt es nur eine Pfeilform.
- **Mikrofon und Systemton:** Das Mikrofon liegt als eigene, synchronisierte AAC-Spur vor. Mit Mikrofon wird es auf 75 % gemischt, der Systemton auf 25 %.
- **Datenschutz:** Passwortfelder und andere private Inhalte werden nicht automatisch geschwärzt.

## Bearbeiten

- **Timeline:**
  - Die obere Leiste (Lineal) zeigt die Originalaufnahme inklusive herausgeschnittener Stellen, die schraffiert sind.
  - Darunter liegen drei Spuren: Clip (Filmstreifen), Zoom und Kamera.
  - Kanten ziehen kürzt, Blöcke ziehen verschiebt, ein Doppelklick in eine leere Spur legt einen neuen Block an.
- **Schnitt:** `⌘B` teilt an der Abspielposition, `⌘⌫` löscht die Auswahl, Start und Ende lassen sich sekundengenau eintippen.
- **Zoom:**
  - Klick-Zooms entstehen automatisch, nahe Klicks werden zusammengefasst.
  - Pro Zoom: Stärke 1–4×, „Cursor folgen“ oder ein fester Fokuspunkt.
  - Während des Zooms wächst die ganze Fensterkarte (Rahmen, Ecken, Schatten) über dem ruhenden Hintergrund.
  - Eine Totzone hält das Bild bei kleinen Cursorbewegungen still, Zero-Phase-Glättung nimmt das Handzittern raus.
  - Im Zoom-Tab stellst du Stärke, Vorlauf und Haltezeit für **Klick-Zooms neu erzeugen** ein.
- **Kamera:**
  - Stile, Form (Kreis, abgerundet, eckig), Seitenverhältnis, Rand, Position, Größe und „Größe beim Zoom“.
  - **Layout im Video** schaltet ab der Abspielposition auf Vollbild, Geteilt oder Ausgeblendet.
- **Look:**
  - **Studio-Hintergründe:** Nachtstudio, Bühne, Tiefsee, Glut, Samt, Nordlicht, Blaue Stunde, Abendrot, Koralle, Papier, Nebel, Pastell. Sie werden in Exportauflösung gerendert, das Grain kommt vor der 8-Bit-Quantisierung dazu.
  - Außerdem klassische Verläufe, eigener Verlauf, Vollfarbe oder ein eigenes Bild mit Weichzeichnen.
  - Rahmen-Presets Dezent/Weich/Präsent, Abstand, Ecken, Schatten und Motion Blur.
- **Format & Ausschnitt** (oben in der Leiste): 16:9, 9:16, 1:1 oder 4:5. Ausschnitt „16:9 · ohne Menüleiste & Dock“, „16:9 · mittig“ oder die ganze Aufnahme.
- **Cursor:** Größe, Glättung, Neigung beim Bewegen, Klick-Effekt (Ring, Puls, Aus).
- **Edits-Menü:** alle Zooms, Schnitte und Kamera-Layouts auf einmal entfernen oder die Klick-Zooms neu erzeugen.
- **Speichern & Wiedergabe:**
  - Alles wird automatisch gespeichert, `⌘Z` und `⌘⇧Z` funktionieren über die ganze Sitzung.
  - Die Wiedergabe läuft in Echtzeit über AVPlayer mit derselben Komposition wie der Export, die Frames sind identisch.
  - **Zuschaueransicht** zeigt das fertige Video groß, ohne Werkzeuge.

## Speicher und Links

- **Einstellungen → Speicher:** Belegung nach Studio, Loom, Meetings, Anleitungen und freier Platz. Aufräumen läuft automatisch einmal am Tag (`Storage.plan`/`Storage.apply` im Core):
  - geteilte Loom-Takes, seit N Tagen unbenutzt (Standard 30, gemessen an der letzten Änderung von `project.json`) → Papierkorb; der Link bleibt;
  - optional Studio-Takes, seit N Tagen unbenutzt → Archiv-Ordner (z. B. externe Platte), dort weiter öffenbar; die „Zuletzt“-Liste zieht mit um.
  - Nie angefasst: Meetings, Anleitungen, das geöffnete Projekt, eine laufende Aufnahme, abgebrochene Takes mit Recovery-Journal.
- **Ablaufende Links:** Die App schickt `X-Focus-Expires-Days` (Standard 90, Einstellungen → Teilen). Der Server löscht abgelaufene Videos endgültig und gibt ihren Platz frei (stündlich und beim Start), zeigt Zuschauern eine „Link abgelaufen“-Seite (HTTP 410) und lässt Links per `PATCH /api/videos/:id {"expiresAt": null}` dauerhaft behalten („Behalten“ in Freigaben verwalten). Videos, die eine geteilte Anleitung einbettet, laufen nicht ab.
- **Bitrate:** Loom-Aufnahme und Loom-Links höchstens 6 Mbit/s (`MovieExporter.loomBitRate`).

## Export

- **MP4 exportieren** stellt den Export in eine Queue im Hintergrund. Gerendert wird der Stand zum Zeitpunkt des Klicks; du kannst weiterarbeiten oder neu aufnehmen.
- **Auflösungen:** 1920×1080 oder 3840×2160, Hochformat 1080×1920 oder 2160×3840. 30 oder 60 fps, H.264 mit AAC-Ton.
- **Tempo** (gemessen an einer 2940×1912/60-fps-Aufnahme): 1080p60 in etwa 2× Echtzeit, 4K60 in etwa 1,1× Echtzeit, gerendert auf mehreren Kernen.
- **Sicherheit:**
  - Exporte entstehen in einem temporären Nachbarordner und ersetzen das Ziel erst bei Erfolg.
  - **Abbrechen** räumt auf und lässt ein vorhandenes Ziel unangetastet.
  - Beenden mit offenen Exporten fragt vorher nach.

## Tests

```sh
./scripts/test.sh                 # Core: Mathe, Validierung, Persistenz, Renderer-Pixel
./scripts/test.sh --integration   # generierte Medien, echte MP4-Decodes, Audio, Formate, Abbruch
./scripts/test.sh --mcp           # MCP-Server: Export-Schutz, Zahlen-Validierung, keine verlorenen Änderungen
./scripts/build-app.sh            # optimierter Build plus Signaturprüfung
```

- Die Command Line Tools bringen kein XCTest mit. Die Tests sind deshalb ein ausführbares Swift-Target, das bei einem Fehler mit Exit-Code ≠ 0 abbricht.
- Testvideos und -bilder werden aus eigener Geometrie und Sinustönen in `build/qa/` erzeugt.

**Entwickler-Diagnosen** laufen nur auf ausdrücklichen Aufruf. Pro Lauf einen frischen Ordner nehmen; echte Aufnahmen bleiben lokal.

```sh
open -n "$HOME/Applications/Rekord.app" --args --diagnostics "$PWD/build/capture-check" --exit-after-diagnostics
open -n "$HOME/Applications/Rekord.app" --args --diagnostics "$PWD/build/capture-check-real" --real-capture --camera --exit-after-diagnostics
```

| Flag | Prüft |
|---|---|
| `--recorder-flow-check <dir>` | kompletter Recorder-Ablauf: Bereich, Fenster verwerfen, Bildschirm neu starten, automatischer 16:9-Zuschnitt, `rekord://`-Befehle |
| `--interface-check <dir>` | Pixel-Gleichheit von Live-Vorschau und Export, Geräte-Übergabe (mit `--real-capture --camera --microphone`) |
| `--playback-check <dir> --project <x.rekord>` | Editor-Wiedergabe, Schnitte, Look-Änderungen |
| `--export-queue-check <dir> --project <x.rekord>` | Export-Queue: Reihenfolge, Snapshots, Abbruch |
| `--ui-live-snapshot <dir> [--project <x.rekord>]` | Screenshots der echten Fenster (Recorder, Editor, Kamera-Tab) |
| `--command-check <dir> --project <x.rekord>` | `rekord://`-Handler: Teilen eines fehlenden/kaputten Projekts, doppelte Parameter, Edit direkt nach externer Änderung |
| `--fault-check <dir>` | echte 3-s-Aufnahme mit absichtlich ausfallendem Mikrofon: Projekt bleibt öffenbar, Warnung erscheint |
| `--loom-check <dir> --share-connection <connection.json>` | Loom von Aufnahme bis Link, Retry und Widerruf gegen einen lokalen Loopback-Service |
| `--meeting-check <dir> --audio <datei> [--no-summary]` | Meeting-Modus echt: Aufnahme, während `afplay` einen Testdialog abspielt; beide Spuren, Zeitachse, Transkript, Benennung aus dem Gespräch, Zusammenfassung ≤ 90 s, nur HTTPS zur Claude-API. Meetings landen in `<dir>/Meetings`. Braucht entsperrten Bildschirm. |
| `--meeting-auto-check <dir> --audio <datei>` | Automatik ohne Klick: ein Stellvertreter (`ffmpeg` am Mikrofon) spielt die Meeting-App; Rekord muss selbst starten, nach Ende selbst stoppen und transkribieren |
| `--meeting-reprocess <meeting-ordner>` | Transkript und Zusammenfassung eines vorhandenen Meetings neu erstellen und Zeit messen (lange Calls ohne Echtzeit-Aufnahme) |

`BLOCKED` im Report heißt: Eine Freigabe fehlt. Das ist kein bestandener Test.

## Struktur

- `Sources/RecorderCore` – Projektformat (versioniertes JSON), Schnitte, Bewegungsmathematik, gemeinsamer Frame-Renderer, Studio-Hintergründe, Playback-Komposition, Exporter, Share-Client.
- `Sources/Rekord` – die App: ScreenCaptureKit/AVFoundation-Recorder, SwiftUI-Editor, schwebender Recorder, Meeting-Modus (`Meeting*.swift`, `SystemAudioTap.swift`), Diagnosen.
- `Sources/RecorderCore/Meeting*.swift` – Meeting-Format, Transkript-Logik (Sätze, Zeitachse, Echo-Filter), Zusammenfassung über die Claude API.
- `Sources/RekordMCP` – MCP-Server für Claude Code (stdio, JSON-RPC).
- `Tests/RecorderCoreTests` – Modell-, Renderer- und Medien-Tests.
- `share-service/` – selbst gehosteter Upload- und Player-Server (Node 22, keine Dependencies).
- `Resources/` – Info.plist, Entitlements, App-Icon (erzeugt mit `scripts/make-icon.swift`).
- `docs/MCP.md` – alle MCP-Werkzeuge mit Beispielen.

Gebaut auf öffentlichen Apple-APIs: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter), [AVAssetWriterInputPixelBufferAdaptor](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor).

## Hinweis zum Namen

Bis Version 1.2.0 hieß die App „Focus Recorder“. `update.sh` zieht ältere Installationen automatisch um: App, MCP-Eintrag, Aufnahmeordner, Keychain-Eintrag und Signing-Identity. Ältere `.focusrec`-Aufnahmen öffnen weiterhin.

Bewusst unverändert bleibt die Bundle-ID `dev.sapunov.FocusRecorder`. Sie ist nirgends sichtbar, hält aber die macOS-Freigaben und Einstellungen.


## Arbeits-Inventur

Lokaler 5-Sekunden-Sampler, Bilder bei Kontextwechsel/30 Sekunden, Text-Zusammenfassung alle 15 Minuten (Sonnet 5.5), Prozess-Katalog am Abend (Opus 5.5). `InventoryRecorder`, `InventoryStore` und `RecorderCore/Inventory*.swift` trennen Erfassung, Oberfläche und Text-Auswertung. Claude-Transport, OCR und AX-Leser sind mit dem Anleitungs-Modus geteilt. Standardbudget 400.000 Tokens pro Tag; ausstehende Blöcke aufbewahrter Tage werden später nachgeholt.

[Bedienung](../README.md#arbeits-inventur) · [Datenschutz](inventur-datenschutz.md) · [Abnahme und Replay](validation/inventory/acceptance.md) · [MCP](MCP.md)
