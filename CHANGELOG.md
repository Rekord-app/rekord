# Changelog

Alle Änderungen an Rekord (bis 1.2.0: „Focus Recorder“). Updaten mit `./scripts/update.sh` (siehe [ANLEITUNG.md](ANLEITUNG.md)).
Neue Einträge kommen oben dazu; die Version steht in `Resources/Info.plist`.

## 1.12.0 – 15.10.2026 · Angebote einmal einrichten

- **Buchungslink & Landingpage** direkt bei Video-Angeboten einrichten: Standardlink, Absender, Farbe, Button-Text und Nachricht mit Vorschau. Ohne gültigen Link startet zuerst die Einrichtung, danach der Upload.
- Neue Angebote übernehmen die Vorlage. Bereits verschickte Links behalten ihre Inhalte; einzelne Seiten lassen sich weiter bearbeiten.
- **Statistik automatisch aktiv:** neue Angebotsseiten erfassen Öffnungen, abgespielte Abschnitte und Button-Klicks ohne vorheriges Ankreuzen. Sichtbarer Hinweis und Ausschaltoption, keine Cookies oder dauerhafte Zuschauer-ID. Neuladen zählt als neue Session; Browser-Datenschutzsignale werden berücksichtigt.
- Hintergrundabfragen blockieren den App-Start bei gesperrtem Schlüsselbund nicht mehr; die Freigabe erfolgt bei Bedarf in den Teilen-Einstellungen.
- Alte Angebote behalten ihre Zustimmungseinstellung. Vorschauen bleiben ohne Messung. Zuerst den Share-Server aktualisieren; ältere Server werden vor dem Upload erkannt.

## 1.11.0 – 15.10.2026 · Meeting-Rückblick

- **Player im Meeting:** beide Spuren zusammen abspielen, ±15 s, Tempo 1× bis 2×. Eine Sprecher-Zeitleiste zeigt, wer wann redet; Klicken oder Ziehen springt an die Stelle. Dazu der Redeanteil (z. B. du 44 %, Gegenüber 56 %).
- **Zusammenfassung passt sich dem Call an:** Rekord erkennt Verkaufsgespräch, Kundengespräch, intern, privat oder sonstiges. Jeder Call bekommt einen echten Titel („Erstgespräch Wagner Logistik“ statt „Google Meet 15:13“), den Zweck in einem Satz, Kernaussagen und Themen mit Zeitmarken sowie nächste Schritte zum Abhaken.
- Interesse, Budget, Entscheider, Einwände und Follow-up erscheinen nur bei Verkaufs- und Kundengesprächen. Leere Felder („nicht angesprochen“) werden ausgeblendet.
- **Jede Zeitmarke ist klickbar** und spielt ab dieser Stelle ab, in Kernaussagen, Themen, Einwänden und im Transkript.
- **Transkript:** Suche mit Markierung; beim Abspielen läuft die aktuelle Stelle mit.
- **Fragen:** „Frag den Call“, z. B. „Was habe ich zugesagt?“ oder „Schreib eine Follow-up-Mail“. Claude antwortet nur aus dem Transkript, mit Zeitmarken. Fragen und Antworten bleiben beim Meeting gespeichert.
- **Transkript kopieren mit einem Klick:** Knopf „Transkript“ oben im Meeting, im Reiter Transkript oder ⌘⇧C. Als reiner Text mit Name und Zeitmarke, bereit für Mail, Dokument oder KI-Chat.
- **Controller unauffällig:** Der Augen-Knopf klappt den Meeting-Controller zu einem kleinen roten Punkt zusammen, ohne Minuten und Pegel. Ein Klick klappt ihn wieder auf. Die Einstellung „Zeit und Pegel während Meetings anzeigen“ startet jeden Call direkt als Punkt. Zusätzlich gibt es einen roten Punkt in der Menüleiste mit Stoppen und Verwerfen. In Bildschirmfreigaben ist der Controller nie zu sehen.
- Der Meeting-Teil liest den Claude-Schlüssel nicht mehr beim Start, sondern erst bei der ersten Zusammenfassung.
- Automatisch aufgenommene Calls unter 45 Sekunden werden verworfen (Fehlauslösungen). Ältere Meetings bekommen die neue Ansicht über ⋯ → „Zusammenfassung neu erstellen“.

## 1.10.0 – 15.10.2026 · Bibliothek mit Ordnern

- **Ordner** für Aufnahmen (z. B. pro Kunde oder Kanal): in der Seitenleiste anlegen, umbenennen und auflösen. Beim Auflösen bleiben die Aufnahmen erhalten. Es sind normale Finder-Ordner in `~/Movies/Rekord`.
- **Verschieben** per Drag-and-drop auf einen Ordner oder über „In Ordner verschieben“ im Kontextmenü. Bei gleichem Namen wird nummeriert statt überschrieben. Eine geöffnete Aufnahme bleibt dabei offen.
- **Kontextmenü** an jeder Aufnahme: Öffnen, Umbenennen, In Ordner verschieben, Im Finder zeigen, In den Papierkorb (mit Rückfrage, im Finder wiederherstellbar). Laufende Aufnahmen und Exporte sind gesperrt.
- **Vollständige Bibliothek:** „Aufnahmen“ zeigt alle Aufnahmen aus dem Aufnahmeordner und seinen Ordnern statt nur der letzten zwölf. Änderungen im Finder erscheinen von selbst.
- **Ruhigerer Kopf:** Titel, Anzahl und Suche ohne Glaskarte; in Ordnern als Pfad „Aufnahmen › Kunden“.
- **„Zuletzt“** zeigt die letzten fünf Aufnahmen und lässt sich per Rechtsklick ausdünnen. Testläufe aus temporären Ordnern landen nicht mehr darin.
- MCP: `list_recordings` und die Speicher-Aufräumung finden Aufnahmen auch in Ordnern; `list_recordings` meldet den Ordner im Feld `folder`.

## 1.9.0 – 15.10.2026 · Video-Angebote

- Eigene Angebotslinks pro Empfänger mit öffentlichem Titel, Nachricht und **Termin buchen**; dieselbe MP4 wird wiederverwendet. Formular im Teilen-Menü und bei vorhandenen Freigaben, Standard-Buchungslink in den Einstellungen.
- Wiedergabe-Statistik nach aktiver Zustimmung: echte abgespielte Intervalle statt Vorspulposition, getrennte Sessions, Terminbutton-Klicks. Video und CTA funktionieren auch ohne Messung.
- Native Auswertung, erste Öffnungsaktivität, lokale macOS-Mitteilungen und Nachladen nach Offlinezeit. Vorschau ohne Statistik, eigene Laufzeit, Linkwiderruf und Statistiklöschung.
- Abwärtskompatibler Server mit atomarer Persistenz, Aufbewahrung, Limits und Fehlerisolierung. Normale Video-, Anleitungs- und MCP-Freigaben bleiben kompatibel.
- [Bedienung und Grenzen](docs/VIDEO-ANGEBOTE.md): kein Identitätsnachweis, keine Buchungsbestätigung und keine sofortigen Mitteilungen bei beendeter App.

## 1.8.1 – Launch-Härtung (noch nicht veröffentlicht)

- Anleitungslinks übertragen keine Rohvideos oder Audios mehr. Schritt-Bilder werden vor dem Upload mit den aktuellen Schwärzungen erzeugt.
- Gemeinsamer, dauerhafter Widerruf von Anleitungsversionen und alten Video-Verknüpfungen; Anleitungslinks in der Freigabeverwaltung.
- Share-Server: Wiederanlauf nach Widerruf, isolierte beschädigte Anleitungen, Kontingent für zurückbehaltene Bilder und begrenzte parallele Uploads. Zuerst Server auf `guide-lifecycle-v2` aktualisieren.
- Meeting-Automatik standardmäßig aus, ausdrückliche Aktivierung und sicherer Umstieg alter Einstellungen. Bestätigungen behaupten keine Zustimmung anderer Personen.
- Funktionsvoraussetzungen und lokale Nutzung ohne Claude-Schlüssel erklärt; Inventur als experimentell gekennzeichnet.
- Öffentlicher Export geprüft; Paketbau und Veröffentlichung getrennt. Release benötigt Developer ID, Notarisierung und passenden öffentlichen Quellstand.

## 1.8.0 – 15.10.2026 · Arbeits-Inventur

- Lokale Inventur im Hintergrund: Arbeitsblöcke, maskierter Fenstertext, automatische Pausen, eigene Ausschlüsse und jederzeit sichtbare Menüleiste. Kein Inventur-Bild verlässt den Mac.
- Kurze Rückfragen per lokaler Sprache oder Text; Prozess-Liste mit tatsächlich beobachteter Häufigkeit, Stunden und Euro-Arbeitswert. Tagesbudget und Aufbewahrung einstellbar, im Speicherbereich sichtbar.
- Übergabe-Pakete an Claude Code, vier Inventur-MCP-Werkzeuge und Eval-Skill mit zehn Testfällen. Team-Modus mit eigener Einwilligung und geprüftem lokalem Prozess-Export.
- Gemeinsamer Claude-Transport/OCR/AX-Leser; Core-Audio-Zeiger und zwei Release-Concurrency-Warnungen bereinigt. Diagnosen überschreiben den Status der laufenden App nicht.
- Abnahme mit Fake-Tag: 6/6 Prozesse, zwei lokale Sprachantworten, 28.267 Tokens; Eval 9,80/10. Live-Abnahme braucht noch Bedienungshilfen-Recht, echte Nutzung und menschliche Stichproben. [Belege](docs/validation/inventory/acceptance.md).

## 1.7.0 – 15.10.2026 · Speicher im Griff

**Neu**
- **Speicher-Übersicht und Aufräumen** (Einstellungen → Speicher): zeigt, wie viel Platz Studio, Loom, Meetings und Anleitungen belegen und was auf dem Mac frei ist. Automatisch einmal am Tag:
  - geteilte Loom-Videos, die seit 30 Tagen (einstellbar) unbenutzt sind, wandern in den Papierkorb – der Link bleibt bestehen, aus dem Papierkorb lässt sich alles zurückholen;
  - auf Wunsch: Studio-Aufnahmen, die seit 60 Tagen unbenutzt sind, auf eine externe Platte auslagern – dort bleiben sie öffenbar.
  Meetings, Anleitungen, die geöffnete und eine laufende Aufnahme fasst das Aufräumen nie an.
- **Links laufen ab:** Neue Video-Links laufen standardmäßig nach 90 Tagen ab (30 Tage, 1 Jahr oder nie einstellbar); danach gibt der Server den Platz frei. Unter **Freigaben verwalten** steht bei jedem Link das Ablaufdatum, **Behalten** macht ihn dauerhaft. Wer einen abgelaufenen Link öffnet, sieht eine klare Seite statt einer Fehlermeldung. Bestehende Links laufen nicht ab.
- **Loom-Links schlanker:** höchstens 6 statt 12 Mbit/s. Gemessen an einer echten Aufnahme ohne sichtbaren Unterschied (SSIM 0,9972 statt 0,9975); spart vor allem bei Scrollen und Videos im Bild.

## 1.6.0 – 15.10.2026 · Neues Design

**Neu**
- **Ein Farbsystem für alles:** eine Akzentfarbe (das Rekord-Rot des Aufnahmepunkts) nur für die Hauptaktion, Auswahlmarken und den Playhead; ein ruhiges Grau-Gerüst dafür. Grün, Gelb und Blau stehen nur noch für Status (Interesse, Warnung, Kamera-Layout).
- **Start = Bibliothek:** Aufnahmen nach Tag gruppiert (Heute, Gestern, Diese Woche …), mit Suche, Studio/Loom-Kennzeichen, Kamera-Symbol und Länge. Darüber die drei Wege zum Aufnehmen: Bildschirm, Meeting, Anleitung.
- **Seitenleiste:** „Neue Aufnahme“ als roter Hauptknopf, Bereiche mit Anzahl, zuletzt geöffnete Aufnahmen mit Datum, Zahnrad für die Einstellungen.
- **Meetings strukturiert:** Liste nach Tag gruppiert, Suche nach Firma, Name und Titel, Filter „Interesse ≥ 4“ und „Nächster Schritt“; Interesse als Punkte-Skala, nächster Schritt direkt in der Zeile. In der Detailansicht stehen Interesse, nächster Schritt, Budget-Signal und Entscheider oben als Kacheln, darunter Kurzfassung, Gespräch, Einwände, Aufgaben und Follow-up-Entwurf; „Follow-up“ und „Notiz“ bestätigen das Kopieren.
- **Anleitungen strukturiert:** Liste nach Tag mit Suche, Kennzeichen „Brief“ und „Geteilt“; Detailansicht mit fest stehender Kopfzeile (Titel, Teilen, PDF, An Claude Code), Automatisierungs-Karte und nummerierten Schritt-Karten.
- **Liquid Glass (macOS 26):** Kopfzeilen über Listen und Detailansichten liegen als Glas über dem Inhalt, der darunter durchscrollt. Schwebende Leiste, Aufnahme-Pille, Countdown (jetzt mit Ring) und Controller bleiben Glas.
- **Editor:** neutrale Schalter und Regler im Inspektor, Zoom-Spur in der Akzentfarbe, Schnittabschnitte neutral mit weißer Auswahlkante, Rahmen-Presets zeigen den aktiven Stand.
- **Eine Einstellungen-Ansicht** (Zahnrad in der Seitenleiste oder bei Meetings): Meetings, Claude-Schlüssel, Share-Server.
- **Share-Seite:** Player-Seite im selben Stil (dunkel, roter Aufnahmepunkt als Marke), Anleitungs-Seite mit derselben Marke.
- Bildschirm- und Fensterauswahl im Recorder werden weiß statt farbig umrandet; Rot bleibt dem Aufnehmen vorbehalten.

**Behoben**
- Ein Export, der genau beim Start der Ton-Phase abgebrochen wurde, konnte die App abstürzen lassen (gefunden im Design-Review). Jetzt endet jeder Abbruch sauber; als Regressionstest an 13 Abbruch-Zeitpunkten abgesichert.

**Für Entwickler**
- `--ui-snapshot` zeigt jetzt auch Meetings, Anleitungen, Einstellungen und die schwebenden Controller, mit synthetischen Daten aus dem Snapshot-Ordner (nie die eigenen Calls). `REKORD_CLAUDE_KEY` und `REKORD_SHARE_TOKEN` in der Umgebung umgehen den Schlüsselbund, damit ein anders signierter Testbuild nicht am Passwort-Dialog hängt.


## 1.5.0 – 15.10.2026 · Anleitungs-Modus

**Neu**
- **Anleitungen (wie Scribe/Tango):** Ablauf am Bildschirm vormachen und erklären, Rekord schreibt die Schritt-für-Schritt-Anleitung. Ein Schritt pro Klick, mit Screenshot, markierter Stelle und Text. Die Knopf-Namen liest Rekord direkt aus der App, auch in nativen Mac-Apps und Electron-Apps. Seitenleiste **Anleitungen**.
- **Datenschutz eingebaut:** E-Mail-Adressen, IBANs, Telefonnummern und Passwörter werden in den Bildern automatisch geschwärzt, Bereiche lassen sich von Hand schwärzen. Getippte Inhalte speichert Rekord nie. An Claude geht nur Text, keine Bilder.
- **Ausgabe:** Teilen-Link mit mobiler Seite und Video, PDF, Markdown und `guide.json` für KI-Agenten.
- **Automatisierungs-Brief:** Welche Schritte lassen sich automatisieren, womit, mit welchem Aufwand und wie viele Stunden pro Monat spart das? **An Claude Code** übergibt den Ablauf als fertigen Auftrag für einen n8n-Entwurf.
- Claude Code: `list_guides` und `get_guide`. Befehle `rekord://guides`, `rekord://guide`, `rekord://guide-stop`.

**Einmalig nötig:** Systemeinstellungen → Datenschutz & Sicherheit → **Bedienungshilfen** → Rekord einschalten. Sonst fehlen in den Anleitungen die Namen der Knöpfe.

## 1.4.0 – 15.10.2026 · Meeting-Modus

**Neu**
- **Meetings (Call-Notizen):** Rekord erkennt Calls in Google Meet, Zoom, Teams, FaceTime (auch Anrufe vom iPhone), Slack und weiteren Apps und nimmt sie **automatisch** auf, ohne Bot. Beim Auflegen stoppt es selbst und meldet „Transkript fertig“.
- Getrennte Spuren für deine Stimme und die Gegenseite, lokales Transkript mit Sprecher-Labels, deutsche Sales-Zusammenfassung über Claude: Interesse 1–5, Schmerz, Budget, Entscheider, wörtliche Einwände, nächster Schritt, Follow-up-Entwurf. Calls werden nach Gesprächspartner und Firma benannt.
- Von Hand mit **⌃⌥⌘M**, Verwerfen per Papierkorb im Controller. Rekord startet beim Anmelden mit (abschaltbar).
- Systemton per eigenem Core-Audio-Tap ohne Musik-Player. Echo-Filter, wenn ohne Kopfhörer telefoniert wird.
- Claude Code: `list_meetings` und `get_meeting`. Befehle `rekord://meetings`, `rekord://meeting`, `rekord://meeting-stop`.
- Enthält die Absicherung aus 1.3.1. Zusätzlich für Meetings: Fällt dein Mikrofon aus, bleibt das Meeting mit der Gegenseite erhalten (statt komplett „fehlgeschlagen“); `list_meetings` lehnt unsinnige Zahlen ab, statt den MCP-Server abstürzen zu lassen; die Meeting-Befehle laufen über den strengen `rekord://`-Parser.

## 1.3.1 – 15.10.2026 · Absicherung

Umsetzung des unabhängigen Reviews vom 15.10.2026; jeder Punkt ist als Regressionstest abgesichert.

**Behoben**
- **Originale sind geschützt:** Kein Export (App, MCP) kann mehr `screen.mov`, Kamera, Mikrofon, `project.json` oder irgendetwas in einem `.rekord`-Ordner überschreiben – auch nicht über `..`, Symlinks oder Hardlinks. MCP-Export überschreibt vorhandene Dateien nur mit `overwrite: true` und nur `.mp4`.
- **Teilen trifft nur das angefragte Projekt:** Ein fehlendes, verschobenes oder kaputtes Projekt wird abgelehnt, statt versehentlich das gerade geöffnete hochzuladen.
- **`rekord://`-Befehle sind fehlertolerant:** doppelte, unbekannte oder kaputte Parameter führen zu einer Fehlermeldung statt zum Absturz. Die App bestätigt jeden Befehl; `share_link` meldet Fehler sofort statt nach 5 Minuten.
- **Teilaufnahmen bleiben erhalten:** Fällt Kamera oder Mikrofon aus, wird die Bildschirmaufnahme trotzdem als Projekt gespeichert (mit Hinweis, welche Spur fehlt); während der Aufnahme erscheint eine Warnung in der Aufnahme-Pille.
- **Absturzsicher:** Aufnahmen werden fragmentiert geschrieben und laufend protokolliert. Stürzt die App ab oder geht der Strom aus, rettet Rekord den Take beim nächsten Start automatisch.
- **Keine verlorenen Änderungen:** Änderungen aus Claude Code (MCP) und aus der App überschreiben sich nicht mehr gegenseitig; Undo/Redo zeigen erst nach erfolgreichem Speichern den neuen Stand.
- **MCP stürzt bei absurden Zahlen nicht mehr ab** (z. B. `height: 1e100`), sondern antwortet mit einem Fehler.
- **Share-Server:** Nur abspielbare Videos (mit Videospur und Dauer) bekommen einen Link; eine beschädigte Metadatei wird in Quarantäne verschoben, statt den ganzen Server lahmzulegen. Footer heißt „Aufgenommen mit Rekord“.
- **Release:** `release.sh` baut exakt den angegebenen Commit aus einem sauberen Checkout und legt ein `manifest.json` (Commit, Version, Architektur, SHA-256) bei.

## 1.3.0 – 14.10.2026 · Rekord

**Neu**
- **Neuer Name: Rekord.** Neues Icon (roter Aufnahmepunkt), App heißt `Rekord.app`, MCP-Server in Claude Code heißt `rekord`, Befehle laufen über `rekord://` (das alte `focusrecorder://` geht weiter).
- `./scripts/update.sh` zieht alles automatisch um: alte App wird ersetzt, MCP-Eintrag umbenannt. Freigaben, Schlüsselbund-Zugang und Aufnahmen bleiben erhalten.
- Aufnahmen heißen jetzt `.rekord` und liegen in `~/Movies/Rekord`. Der alte Ordner `~/Movies/Focus Recorder` wird beim ersten Start automatisch umgezogen; ältere `.focusrec`-Aufnahmen öffnen weiter.
- **Download als fertige App:** `Rekord.zip` unter GitHub Releases, Installation ohne Xcode (Anleitung oben in der README).
- Rekord-Schriftzug mit Aufnahmepunkt in der Seitenleiste.
- Auch intern umbenannt: Code (`Sources/Rekord`), Schlüsselbund-Eintrag (der Upload-Schlüssel wird einmal übernommen), Einstellungsordner, Signatur. Nur die unsichtbare App-Kennung bleibt, damit Freigaben und Einstellungen erhalten bleiben.

## 1.2.0 – 14.10.2026

**Neu**
- **Studio-Hintergründe:** zwölf neue Hintergründe für YouTube und Erklärvideos (Nachtstudio, Bühne, Tiefsee, Glut, Samt, Nordlicht, Blaue Stunde, Abendrot, Koralle, Papier, Nebel, Pastell). Weiches Licht, feines Filmkorn, keine Farbstufen nach dem YouTube-Encoding. Neuer Standard: Nachtstudio.
- **MacBook → 16:9 automatisch:** Aufnahmen des ganzen MacBook-Bildschirms verlieren Menüleiste und Dock und füllen 16:9 randlos, in Studio und Loom. Abschaltbar im ⋯-Menü des Recorders.
- **Kamera-Stile:** Bubble, Kachel, Breit, Hochkant, Polaroid. Dazu Seitenverhältnis 1:1, 4:3, 16:9 oder 3:4.
- **Kamera-Layouts im Video:** Vollbild, Geteilt (Bildschirm und Kamera nebeneinander) und Ausgeblendet, als eigene Spur in der Timeline und nachträglich änderbar.
- **MCP:** `edit_camera_layouts`, außerdem `camera_preset` und `camera_aspect` in `update_look`.
- **Installation und Update per Skript** (`scripts/install.sh`, `scripts/update.sh`), deutsche Anleitung.

**Behoben**
- Beim Loom-Teilen fragte macOS jedes Mal nach dem Schlüsselbund-Passwort. Jetzt höchstens einmal pro App-Start, mit „Immer erlauben“ gar nicht mehr.

## 1.1.x – 14.10.2026

- **Recorder wie ein natives Aufnahme-Tool:** schwebende Glas-Leiste, Auswahl von Bildschirm, Fenster oder Bereich direkt auf dem Bildschirm, Kamera-Bubble, Aufnahme-Pille mit Pause, Neustart und Verwerfen; globale Kürzel ⌘⇧1, ⌘⇧2, ⌘⇧P und Esc.
- **Editor neu:** Filmstreifen-Timeline, Zooms und Schnitte direkt ziehbar, Edits-Menü (alle Zooms und Schnitte auf einmal entfernen).
- **Saubere Kamera:** macOS-artige Rundungen, weicher Schatten, wird beim Zoomen kleiner oder größer.
- **MCP-Server für Claude Code** und `focusrecorder://`-Befehle: aufnehmen, bearbeiten, ansehen, exportieren und teilen per Agent. Die App lädt Änderungen von außen automatisch nach.
- Bereichsaufnahme (z. B. 16:9 unter der Menüleiste), Pause/Fortsetzen (Pausen werden zu Schnitten, Ton bleibt synchron), Export-Warteschlange im Hintergrund.
- Formate 16:9, 9:16, 1:1, 4:5; Ausschnitt-Presets; Cursor-Neigung und Klick-Effekte; einstellbare Klick-Zooms.
- Zooms auf einer kritisch gedämpften Feder, die ganze Fensterkarte zoomt über einem ruhenden Hintergrund, GPU-Bewegungsunschärfe.
- Echtzeit-Vorschau im Editor, pixelgleich mit dem Export; Export 2–4× schneller; sRGB/BT.709-Farben.
- Stabile lokale Signatur: Freigaben bleiben über Updates erhalten.

## 1.0 – 14.10.2026

- Native Aufnahme von Bildschirm, Fenster, Ton, Mikrofon und Kamera (ScreenCaptureKit, AVFoundation).
- Studio-Modus mit Hintergründen, Rahmen, Cursor-Glättung, automatischen Klick-Zooms, Schnitt und MP4-Export.
- Loom-Modus: Komposition schon während der Aufnahme, Link direkt nach dem Stoppen.
- Eigener Share-Server (`share-service/`) mit Browser-Player und widerrufbaren Links.
