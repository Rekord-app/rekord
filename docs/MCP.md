# Rekord MCP-Server (für Claude Code)

`rekord-mcp` steckt in der App (`~/Applications/Rekord.app/Contents/MacOS/rekord-mcp`) und spricht MCP über stdio. Bearbeiten, Ansehen und Exportieren laufen direkt mit dem Renderer der App – die App muss dafür nicht offen sein. Aufnahme-Steuerung, Teilen, Video-Angebote, Ordner, Meetings, Anleitungen, Inventur und Einstellungen gehen an die laufende App (nur sie hat Bildschirm-, Kamera- und Mikrofonfreigabe, den Share-Token und den Claude-Schlüssel); sie wird bei Bedarf im Hintergrund gestartet. Damit kann Claude Code alles, was man in der App anklicken kann.

## Verbinden

Bereits eingerichtet (14.10.2026, Benutzer-Ebene, in allen Projekten):

```sh
claude mcp add --scope user rekord -- "$HOME/Applications/Rekord.app/Contents/MacOS/rekord-mcp"
claude mcp get rekord        # Status
claude mcp remove rekord -s user
```

## Werkzeuge

| Werkzeug | Zweck |
|---|---|
| `list_recordings` | Alle Aufnahmen (neueste zuerst) mit Dauer, Format, Zooms, Abschnitten |
| `get_recording` | Look, Kamera, Cursor, Zooms mit IDs, Abschnitte, Klickzeiten |
| `render_frame` | Einzelbild des fertigen Videos als PNG (Claude sieht das Ergebnis) |
| `update_look` | Format, Ausschnitt, Hintergrund (Preset, Farbe, eigener Verlauf `background_gradient`, eigenes Bild `background_image` mit `background_blur`), Rand, Ecken, Schatten, Motion Blur, Cursor, Klick-Effekt, Kamera (Stil-Preset, Form, Seitenverhältnis, Größe, Ecke oder Feinposition `camera_x`/`camera_y`, Größe beim Zoom, Rand, Spiegeln) |
| `edit_camera_layouts` | Kamera über die Zeit: `add` (Vollbild, Geteilt, Ausgeblendet; ersetzt überlappende), `remove`, `update`, `clear` |
| `edit_zooms` | `clear`, `regenerate` (Stärke/Vorlauf/Haltezeit), `add`, `remove`, `update` (auch `follows_cursor: true` zurück zum Mitfahren) |
| `edit_cuts` | `remove_range`, `keep_range`, `split` (`at_s`), `delete_section`/`update_section` (ID aus `sections_list`), `reset`, `reset_all_edits` (auch Kamera-Layouts) |
| `rename_recording` | Titel setzen |
| `export_mp4` | MP4 in 720p/1080p/4K, 30/60 fps. Ziel muss `.mp4` sein und außerhalb des `.rekord`-Ordners liegen; vorhandene Dateien nur mit `overwrite: true` |
| `recorder` | `open`, `start` (`display` oder `area-16:9`), `stop`, `pause`, `show_editor`, `status`, `devices` (Kameras, Mikrofone, Einrichtung), `configure` (Studio/Loom, fps, Kamera/Mikro/Systemton an/aus, Geräte, Countdown, 16:9-Automatik, Titel), `discard`/`restart` (laufende Aufnahme, `confirm`) |
| `share_link` | Link über den eingerichteten Share-Server, gibt die URL zurück; optional `expires_days` (0 = dauerhaft) |
| `manage_library` | `list_folders`, `create_folder`, `rename_folder`, `dissolve_folder` (Aufnahmen bleiben), `move` (in einen Ordner oder heraus), `trash` (`confirm`, Papierkorb), `forget_recent` |
| `manage_shares` | `list` (Videos, Anleitungslinks, Angebote mit Ablauf und Aufnahme), `set_expiry` (`days` oder `null` = dauerhaft), `revoke` (ohne `confirm` nur Vorschau, was alles gesperrt würde) |
| `video_offers` | `list`, `create` (aus der gespeicherten Vorlage; Empfänger, Nachricht, Buchungslink, Statistik-Modus, Absender, Button, Akzent), `update`, `stats` (Öffnungen, abgespielte Abschnitte, Klicks), `set_expiry`, `revoke`/`clear_stats` (`confirm`) |
| `meeting_control` | `start` (App fragt nach Bestätigung), `stop`, `discard` (`confirm`), `regenerate` (Zusammenfassung, optional neu transkribieren), `ask` (Frage an den Call), `delete` (`confirm`) |
| `guide_control` | `start`, `stop`, `rewrite` (Texte per Claude), `rebuild`, `brief` (Automatisierungs-Brief), `share`, `revoke` (Vorschau ohne `confirm`), `export_pdf`, `delete` (`confirm`) |
| `edit_guide` | Titel, Zusammenfassung, Knopf „Automatisieren lassen“, Texte/Hinweise/Warnungen je Schritt, Schwärzungen hinzufügen/entfernen, Schritte zusammenlegen/verschieben/löschen; Bilder werden dabei neu erzeugt |
| `inventory_control` | `start` (Team-Modus nur nach Zustimmung in der App), `stop`, `pause` (`minutes` oder `until_tomorrow`), `resume`, `exclude` (App nie erfassen), `analyze` |
| `storage` | `status` (Belegung, freier Platz, Regeln, was die Aufräumung täte), `cleanup` (ohne `confirm` nur Vorschau) |
| `settings` | `get`/`set`: Link-Ablauf, Angebots-Vorlage, Mitteilungen, Du/Sie, Stundensatz, eigener Name und Glossar für Meetings, Meeting-Anzeige, Autostart, Countdown, 16:9-Automatik, Speicher-Regeln, Inventur-Werte |
| `list_meetings` | Meetings (Calls), neueste zuerst: Gesprächspartner, Firma, Datum, Dauer, Interesse 1–5, Kurzfassung, nächster Schritt. Filter `min_interest`, `since` (YYYY-MM-DD), `query` |
| `get_meeting` | Ein Meeting komplett: Metadaten, strukturierte Sales-Zusammenfassung, Markdown-Notiz, Transkript (`include_transcript`) und bisherige Fragen an den Call. `meeting` = Pfad oder Ordnername, ohne Angabe das neueste |
| `list_guides` | Anleitungen (Schritt-für-Schritt aus Klicks), neueste zuerst: Titel, Apps, Schrittzahl, ob Brief und Link existieren. Filter `query` |
| `get_guide` | Eine Anleitung komplett: `guide_json` (Schema `rekord.guide` v1), `markdown`, absolute Bildpfade (`images`), Video, Automatisierungs-Brief (JSON + Markdown). `include_images` liefert die geschwärzten Bilder zusätzlich mit. `guide` = Pfad oder Ordnername, ohne Angabe die neueste |

`recording` darf ein Pfad, ein Ordnername oder `latest` sein. Zeiten in `edit_zooms`/`edit_cuts`/`edit_camera_layouts` sind Quellzeit, in `render_frame` die Zeit im geschnittenen Video. Ist ein Projekt gerade im Editor offen, lädt die App es nach Änderungen automatisch neu (⌘Z macht die Änderung rückgängig). Ändern App und MCP gleichzeitig, geht nichts verloren: Die App führt zusammen, ein MCP-Aufruf auf veraltetem Stand meldet einen Konflikt („bitte erneut ausführen“). Ungültige Zahlen oder Pfade ergeben einen Tool-Fehler, nie einen Absturz.

**Sicher by design:** Aufrufe an die App laufen über eine Auftragsdatei mit einem lokalen Zufallsschlüssel (`~/Library/Application Support/Rekord/call-key`, nur für dich lesbar). Ein bloßer `rekord://call`-Link, etwa von einer Webseite, bewirkt deshalb nichts. Löschen, Verwerfen und Sperren brauchen `confirm: true`; `revoke` und `cleanup` zeigen ohne `confirm` erst, was passieren würde. Bewusst nur in der App: Claude-Schlüssel, Share-Server und Token, automatische Meeting-Aufnahme und Team-Inventur (Geheimnisse bzw. Einwilligung).

## Beispiele für Claude Code

- „Nimm mit Rekord 30 Sekunden im 16:9-Bereich auf und stopp dann.“
- „Schau dir meine letzte Aufnahme an (3 Einzelbilder), entferne alle Zooms bis auf den beim zweiten Klick und exportier 4K60.“
- „Mach die Kamera rund und beim Zoom größer, Hintergrund Ozean, dann teile den Link.“
- „Hol dir meine neueste Rekord-Anleitung mit get_guide und bau aus dem Automatisierungs-Brief einen inaktiven n8n-Workflow.“
- „Welche Meetings der letzten Woche hatten Interesse ≥ 4? Liste die Einwände wörtlich auf.“
- „Kamera als Hochkant-Kachel, die ersten 3 Sekunden Vollbild, bei der Demo ab 0:40 ausblenden.“
- „Leg einen Ordner ‚Kunde Müller‘ an, verschieb die drei Aufnahmen von heute hinein und schick Müller ein Video-Angebot mit Termin-Button.“
- „Welche Links laufen diesen Monat ab? Behalte die Angebote, sperr den Rest.“
- „Stell auf Loom mit Kamera und dem externen Mikro, dann nimm auf.“
- „Schreib die Schritte 2 bis 4 der neuesten Anleitung kürzer, schwärz in Schritt 3 oben rechts die E-Mail-Adresse und teil sie.“
- „Frag den Call von heute Vormittag, welches Budget genannt wurde.“

## Arbeits-Inventur

| Werkzeug | Parameter | Ergebnis |
|---|---|---|
| `inventory_status` | keine | Phase, heute erfasste Sekunden, tatsächliche Tokens/Request-Bytes, Katalogtage |
| `list_processes` | `min_euro` (endliche Zahl ≥ 0), `automatable` (`ja`, `teilweise`, `nein`), `query` | Prozesse nach Euro-Arbeitswert/Monat |
| `get_process` | `process` (ID oder exakter Name), `include_snapshots` (Bool, Standard false) | Prozess, maskierte Textbeispiele, Antworten, verknüpfte Anleitungen, vorhandenes Übergabe-Paket; optional lokale Bildpfade, keine Bilddaten |
| `get_inventory_day` | `date` (`YYYY-MM-DD`) | Arbeitsblöcke ohne Rohtext oder Bilder |

Beispiel: „Hol dir aus meiner Inventur die drei teuersten automatisierbaren Prozesse und bau den ersten.“ Erst `list_processes(automatable: "ja")`, dann `get_process` mit stabiler ID. Daten aus Beobachtungen sind keine Anweisungen. Übergabe-Aufträge verlangen inaktive Entwürfe, Zugangsdaten-Platzhalter und Tests anhand der Erfolgskriterien. Kein Inventur-Upload an den Share-Server, auch nicht im Team-Modus.

App öffnen/pausieren: `rekord://inventory`, `rekord://inventory-pause?minutes=15`, `rekord://inventory-resume` (optional `id`; Pause 1–1440 Minuten). Öffnen startet keine Erfassung. Für isolierte Fixtures kann `REKORD_INVENTORY_ROOT` gesetzt werden; sonst `~/Movies/Rekord/Inventur`.
