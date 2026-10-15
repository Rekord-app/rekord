# Rekord MCP-Server (für Claude Code)

`rekord-mcp` steckt in der App (`~/Applications/Rekord.app/Contents/MacOS/rekord-mcp`) und spricht MCP über stdio. Bearbeiten, Ansehen und Exportieren laufen direkt mit dem Renderer der App – die App muss dafür nicht offen sein. Aufnahme-Steuerung und Teilen gehen über das URL-Schema `rekord://` an die laufende App (nur sie hat Bildschirm-, Kamera- und Mikrofonfreigabe).

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
| `update_look` | Format, Ausschnitt, Hintergrund (Preset/Farbe), Rand, Ecken, Schatten, Motion Blur, Cursor, Klick-Effekt, Kamera (Stil-Preset, Form, Seitenverhältnis, Größe, Position, Größe beim Zoom, Rand, Spiegeln) |
| `edit_camera_layouts` | Kamera über die Zeit: `add` (Vollbild, Geteilt, Ausgeblendet; ersetzt überlappende), `remove`, `update`, `clear` |
| `edit_zooms` | `clear`, `regenerate` (Stärke/Vorlauf/Haltezeit), `add`, `remove`, `update` |
| `edit_cuts` | `remove_range`, `keep_range`, `reset`, `reset_all_edits` |
| `rename_recording` | Titel setzen |
| `export_mp4` | MP4 in 720p/1080p/4K, 30/60 fps. Ziel muss `.mp4` sein und außerhalb des `.rekord`-Ordners liegen; vorhandene Dateien nur mit `overwrite: true` |
| `recorder` | `open`, `start` (`display` oder `area-16:9`), `stop`, `pause`, `show_editor`, `status` |
| `share_link` | Link über den eingerichteten Share-Server, gibt die URL zurück |
| `list_meetings` | Meetings (Calls), neueste zuerst: Gesprächspartner, Firma, Datum, Dauer, Interesse 1–5, Kurzfassung, nächster Schritt. Filter `min_interest`, `since` (YYYY-MM-DD), `query` |
| `get_meeting` | Ein Meeting komplett: Metadaten, strukturierte Sales-Zusammenfassung, Markdown-Notiz und Transkript (`include_transcript`). `meeting` = Pfad oder Ordnername, ohne Angabe das neueste |

| `list_guides` | Anleitungen (Schritt-für-Schritt aus Klicks), neueste zuerst: Titel, Apps, Schrittzahl, ob Brief und Link existieren. Filter `query` |
| `get_guide` | Eine Anleitung komplett: `guide_json` (Schema `rekord.guide` v1), `markdown`, absolute Bildpfade (`images`), Video, Automatisierungs-Brief (JSON + Markdown). `include_images` liefert die geschwärzten Bilder zusätzlich mit. `guide` = Pfad oder Ordnername, ohne Angabe die neueste |

`recording` darf ein Pfad, ein Ordnername oder `latest` sein. Zeiten in `edit_zooms`/`edit_cuts`/`edit_camera_layouts` sind Quellzeit, in `render_frame` die Zeit im geschnittenen Video. Ist ein Projekt gerade im Editor offen, lädt die App es nach Änderungen automatisch neu (⌘Z macht die Änderung rückgängig). Ändern App und MCP gleichzeitig, geht nichts verloren: Die App führt zusammen, ein MCP-Aufruf auf veraltetem Stand meldet einen Konflikt („bitte erneut ausführen“). Ungültige Zahlen oder Pfade ergeben einen Tool-Fehler, nie einen Absturz.

## Beispiele für Claude Code

- „Nimm mit Rekord 30 Sekunden im 16:9-Bereich auf und stopp dann.“
- „Schau dir meine letzte Aufnahme an (3 Einzelbilder), entferne alle Zooms bis auf den beim zweiten Klick und exportier 4K60.“
- „Mach die Kamera rund und beim Zoom größer, Hintergrund Ozean, dann teile den Link.“
- „Hol dir meine neueste Rekord-Anleitung mit get_guide und bau aus dem Automatisierungs-Brief einen inaktiven n8n-Workflow.“
- „Welche Meetings der letzten Woche hatten Interesse ≥ 4? Liste die Einwände wörtlich auf.“
- „Kamera als Hochkant-Kachel, die ersten 3 Sekunden Vollbild, bei der Demo ab 0:40 ausblenden.“
