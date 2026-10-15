# Rekord – Anleitung

Bildschirmaufnahmen für YouTube und Erklärvideos auf dem Mac: automatische Zooms auf Klicks, Kamera, schöne Hintergründe, Schnitt und Export. Dazu ein Loom-Modus, der nach dem Stoppen sofort einen Link erzeugt.

Was neu ist, steht im [CHANGELOG](CHANGELOG.md). Technische Details findest du in der [README](README.md).

---

## 1. Installieren (einmalig, ca. 3 Minuten)

**Voraussetzungen:** Mac mit Apple-Chip (M1 oder neuer), macOS 14 oder neuer (am schönsten ab macOS 26) .

### Weg A – App herunterladen (empfohlen)

1. **[Rekord.zip herunterladen](https://github.com/Rekord-app/rekord/releases/latest/download/Rekord.zip).** Das ist immer die neueste Version. Du musst dafür bei GitHub eingeloggt sein; alle Versionen findest du unter [Releases](https://github.com/Rekord-app/rekord/releases).
2. Die ZIP-Datei doppelklicken und **`Rekord.app` in den Ordner „Programme“ ziehen**.
3. **Rekord öffnen.** Beim allerersten Mal blockiert macOS die App, weil sie nicht über den Apple-Entwickler-Store signiert ist, sondern mit einem eigenen Zertifikat:
   - Im Dialog auf **Fertig** klicken.
   - **Systemeinstellungen → Datenschutz & Sicherheit** öffnen, ganz nach unten scrollen und bei „Rekord wurde blockiert“ auf **Dennoch öffnen** klicken (je nach macOS-Version heißt der Knopf „Trotzdem öffnen“). Mit deinem Mac-Passwort bestätigen.
   - Alternativ im Terminal: `xattr -dr com.apple.quarantine /Applications/Rekord.app`
4. **Freigaben erteilen.** macOS fragt nach **Bildschirmaufnahme**, **Kamera** und **Mikrofon**. Alles erlauben. Nach der Freigabe für die Bildschirmaufnahme die App einmal mit ⌘Q beenden und neu öffnen.
5. **Optional: mit Claude Code verbinden.** Einmal im Terminal ausführen:
   ```sh
   claude mcp add --scope user rekord -- /Applications/Rekord.app/Contents/MacOS/rekord-mcp
   ```

### Weg B – aus dem Quellcode bauen (für Entwickler)

1. **Xcode Command Line Tools** installieren, falls noch nicht vorhanden: `xcode-select --install`
2. **Repository klonen.** Lege es außerhalb von iCloud ab, denn iCloud beschädigt die Signatur der App:
   ```sh
   mkdir -p ~/Code && cd ~/Code
   git clone https://github.com/Rekord-app/rekord.git
   cd rekord
   ```
3. **Installieren:** `./scripts/install.sh`. Das Skript baut die App, legt sie unter `~/Applications/Rekord.app` ab, verbindet sie mit Claude Code (falls installiert) und startet sie. Die App wird dabei mit einem eigenen, lokalen Zertifikat auf deinem Mac signiert.
4. Freigaben erteilen wie oben.

Bitte nur **einen** der beiden Wege nutzen. Zwei Rekord-Apps auf demselben Mac verwirren macOS.

## 2. Updaten

**Weg A (Download):** Rekord beenden (⌘Q), die neue [Rekord.zip](https://github.com/Rekord-app/rekord/releases/latest/download/Rekord.zip) herunterladen, entpacken und `Rekord.app` in „Programme“ ziehen → **Ersetzen**. Fragt macOS wieder, wie beim ersten Mal **Dennoch öffnen**. Freigaben, Einstellungen und Aufnahmen bleiben erhalten, weil jede Version mit demselben Zertifikat signiert ist.

**Weg B (Quellcode):**
```sh
cd ~/Code/rekord
./scripts/update.sh
```
Das Skript holt die neueste Version, zeigt dir die Neuerungen, beendet die laufende App, baut neu und startet sie wieder. Läuft gerade eine Aufnahme oder ein Export, bricht es ab, damit nichts verloren geht.

Was in einer neuen Version steckt, steht unter [Releases](https://github.com/Rekord-app/rekord/releases) und im [CHANGELOG](CHANGELOG.md).

## 3. Aufnehmen

**⌘⇧1** oder **Neue Aufnahme** öffnet den Recorder: eine Leiste unten am Bildschirm und die Kamera-Bubble.

- **Quelle:** ganzer Bildschirm, ein Fenster oder ein Bereich. Fahr mit der Maus darüber und klick.
- **Modus:**
  - **Studio** für YouTube und Erklärvideos. Danach bearbeitest du alles im Editor.
  - **Loom** für schnelle Links. Nach dem Stoppen wird hochgeladen und der Link liegt in der Zwischenablage.
- **⋯-Menü:** Bildrate (30 oder 60 fps; für YouTube 60), Videoformat, Countdown und der **automatische 16:9-Zuschnitt für MacBooks**.

| Kürzel | Aktion |
|---|---|
| **⌘⇧1** | Recorder öffnen / Aufnahme starten |
| **⌘⇧2** | Stoppen |
| **⌘⇧P** | Pause / weiter (Pausen werden automatisch herausgeschnitten) |
| **Esc** | Countdown abbrechen bzw. Recorder schließen (vor der Aufnahme) |

Die Pille zeigt die Zeit und hat Knöpfe für Pause, Neustart und Verwerfen.

**MacBook und 16:9:** MacBook-Bildschirme sind höher als 16:9. Nimmst du den ganzen Bildschirm auf, schneidet die App Menüleiste und Dock automatisch weg. So füllt das Video YouTube und Loom randlos. Was ganz unten am Bildschirm liegt, ist dann nicht im Bild. Soll ein Fenster komplett drin sein, nimm einen 16:9-**Bereich** auf.

### Meetings: Calls mitschreiben

Rekord nimmt deine Calls **automatisch** auf. Du musst nichts klicken.

1. Starte ein Google Meet, Zoom, Teams, FaceTime oder einen Anruf vom iPhone über den Mac. Nach etwa 6 Sekunden beginnt die Aufnahme. Oben rechts zeigt ein kleiner Controller App, Zeit und Pegel.
2. Hol dir wie immer im Gespräch das Okay für die Aufnahme.
3. Leg auf. Rekord stoppt von selbst. Nach wenigen Sekunden meldet sich „Transkript fertig“, ein Klick öffnet Transkript, Zusammenfassung und Follow-up-Entwurf.

Von Hand: **⌃⌥⌘M** startet und stoppt. Der Papierkorb im Controller verwirft eine Aufnahme, die du nicht willst.

Einmalig einrichten:
- **Einstellungen (Zahnrad in der Seitenleiste oder im Meeting-Bereich):** Claude-API-Schlüssel, dein Name, Begriffe, die oft fallen (z. B. Produktnamen). Dort schaltest du auch die Automatik und den Start beim Anmelden ab.
- **Erste Aufnahme:** macOS fragt nach „Systemaudio aufnehmen“ und nach Mitteilungen. Beides erlauben, sonst bleibt die Spur der Gegenseite stumm und die Meldung kommt nicht.
- **Rekord muss laufen**, damit die Automatik greift. Deshalb startet Rekord beim Anmelden mit. Das Fenster darfst du schließen.

Tipps:
- **Kopfhörer** geben das sauberste Transkript. Über Lautsprecher geht es auch, Rekord filtert das Echo heraus.
- **Google Meet im Browser** wird erkannt, wenn der Meet-Tab beim Start der vordere Tab ist.
- **Telefon-Calls** landen nur auf dem Mac, wenn du sie über „Anrufe vom iPhone“ (FaceTime-App am Mac) führst. Telefonierst du direkt am iPhone, gibt es nichts aufzunehmen.

### Anleitungen: Abläufe dokumentieren

Seitenleiste **Anleitungen** → **Anleitung aufnehmen**.

1. Den Ablauf ganz normal durchklicken und dabei laut sagen, was du tust und warum („Jetzt auf Neue Rechnung, die Kundennummer steht im CRM“).
2. **Anleitung fertig** im schwebenden Controller klicken. Nach wenigen Sekunden stehen die Schritte mit Bildern in der App.
3. Texte prüfen, unnötige Schritte löschen oder zusammenlegen, falls nötig einen Bereich schwärzen.
4. **Teilen** (Link in die Zwischenablage), **PDF** oder ⋯ → **Markdown kopieren**.
5. Optional: „Wie oft pro Woche?“ eintragen und **Brief erstellen**. Dann siehst du, was sich davon automatisieren lässt und was es spart. **An Claude Code** kopiert einen fertigen Auftrag für einen n8n-Entwurf.

Einmalig einrichten:
- **Bedienungshilfen:** Beim ersten Mal fragt macOS danach. Erlauben (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Rekord), sonst fehlen die Namen der Knöpfe.
- **Claude-Schlüssel:** derselbe wie bei den Meetings (Einstellungen → Claude). Ohne ihn gibt es einfache Vorlagen-Texte.

Gut zu wissen:
- E-Mail-Adressen, IBANs, Telefonnummern und Passwörter werden in den Bildern automatisch geschwärzt. Vor dem Teilen trotzdem einmal durchscrollen.
- Getippte Inhalte speichert Rekord nie. In der Anleitung steht nur „Trage die Kundennummer ein“.
- An Claude geht nur Text, keine Bilder.

## 4. Bearbeiten (Studio)

Nach dem Stoppen öffnet sich der Editor. Alles wird automatisch gespeichert, **⌘Z** macht jede Änderung rückgängig, und die Originalaufnahme bleibt immer erhalten.

- **Look:** Hintergrund, Rand, Ecken und Schatten.
  - Die **Studio-Hintergründe** (Nachtstudio, Blaue Stunde, Nordlicht, Papier …) sind für YouTube gebaut: weiches Licht und feines Korn, keine Farbstufen nach dem YouTube-Encoding.
  - Du kannst auch eine eigene Farbe oder ein eigenes Bild verwenden.
- **Format und Ausschnitt** (oben): 16:9, 9:16, 1:1 oder 4:5; Ausschnitt ohne Menüleiste und Dock.
- **Cursor:** Größe, Glättung, Neigung und Klick-Effekt.
- **Kamera:**
  - Stile (Bubble, Kachel, Breit, Hochkant, Polaroid), Form, Seitenverhältnis, Position und Größe. Beim Zoomen wird die Kamera kleiner.
  - **Layout im Video:** ab der Abspielposition **Vollbild**, **Geteilt** (Bildschirm und Kamera nebeneinander) oder **Ausgeblendet**. Die Layouts liegen als eigene Spur in der Timeline. Du kannst sie verschieben und in der Länge ziehen, ein Rechtsklick wechselt das Layout.
- **Zoom:** Klick-Zooms werden automatisch erzeugt. In der Timeline kannst du sie verschieben, verlängern oder löschen. Ein Doppelklick in die Zoom-Spur legt einen eigenen Zoom an.
- **Schnitt:** **⌘B** teilt an der Abspielposition, **⌘⌫** löscht die Auswahl, an den Kanten kürzt du.
- **Edits-Menü:** entfernt alle automatischen Edits auf einmal oder erzeugt die Klick-Zooms neu.

**Leertaste** spielt ab. Was du im Editor siehst, ist pixelgenau das spätere Video.

## 5. Exportieren und Teilen

- **Exportieren:** MP4 in 1080p oder 4K, 30 oder 60 fps. Der Export läuft im Hintergrund, du kannst währenddessen weiterarbeiten.
- **Link teilen:** lädt das fertige Video auf den Share-Server und kopiert den Link. Jeder mit dem Link kann das Video ansehen. Im Export-Tab kannst du unter **Freigaben verwalten** Links wieder deaktivieren.

- **Ablaufdatum:** Neue Video-Links laufen nach 90 Tagen ab (ändern unter Einstellungen → Teilen). Willst du einen Link dauerhaft, klick unter **Freigaben verwalten** auf **Behalten**.
- **Speicher:** Unter Einstellungen → Speicher siehst du, was wie viel Platz belegt. Geteilte Loom-Videos wandern nach 30 Tagen automatisch in den Papierkorb (der Link bleibt). Studio-Aufnahmen kannst du nach 60 Tagen auf eine externe Platte auslagern lassen; dort öffnest du sie wie gewohnt.

**Share-Server einrichten:** Dafür brauchst du eine Verbindungsdatei von dem, der euren Share-Server betreibt (oder du betreibst ihn selbst, siehe [share-service/README.md](share-service/README.md)). Unter **Link teilen → Verbindung importieren …** wählst du sie aus und bestätigst mit **Prüfen & speichern**. Die Datei enthält einen Upload-Schlüssel: Gib sie nur über einen sicheren Weg weiter (z. B. einen Passwortmanager), nie per Git oder in Gruppenchats. Der Schlüssel liegt danach im macOS-Schlüsselbund.

Fragt macOS nach einem Update einmal nach dem Schlüsselbund-Passwort, gib dein Mac-Passwort ein und klick **Immer erlauben**.

## 6. Mit Claude Code steuern (MCP)

`install.sh` meldet die App automatisch bei Claude Code an. Danach geht in Claude Code zum Beispiel:

- „Nimm 30 Sekunden im 16:9-Bereich auf und stopp dann.“
- „Schau dir meine letzte Aufnahme an, entferne alle Zooms außer dem zweiten und exportier 4K60.“
- „Kamera als Hochkant-Kachel, die ersten 3 Sekunden Vollbild, Hintergrund Blaue Stunde, dann teile den Link.“
- „Welche Calls von heute hatten Interesse ab 4? Gib mir jeweils den nächsten Schritt und den Follow-up-Entwurf.“

Die Liste aller Werkzeuge steht in [docs/MCP.md](docs/MCP.md). Nach einem Update startest du eine neue Claude-Code-Sitzung, damit neue Werkzeuge erscheinen.

## 7. Wenn etwas nicht geht

| Problem | Lösung |
|---|---|
| Schwarzes Bild oder „Bildschirmaufnahme fehlt“ | Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme → Rekord an. Danach die App mit ⌘Q beenden und neu öffnen. |
| Kamera oder Mikrofon fehlt | Gleicher Ort, unter **Kamera** bzw. **Mikrofon**. |
| Schlüsselbund-Dialog beim Teilen | Mac-Passwort eingeben und **Immer erlauben** klicken. Nach einem Update kommt das einmal wieder. |
| „Rekord kann nicht geöffnet werden“ / „wurde blockiert“ | Systemeinstellungen → Datenschutz & Sicherheit → ganz unten **Dennoch öffnen**. Oder: `xattr -dr com.apple.quarantine /Applications/Rekord.app` |
| `install.sh`: „Swift fehlt“ | `xcode-select --install` ausführen und danach das Skript erneut starten. |
| `update.sh`: „Not possible to fast-forward“ | Du hast lokale Änderungen. Sichern oder verwerfen (`git status`), dann erneut versuchen. |
| Nach dem Update auf Rekord fehlen Freigaben | Einmal Bildschirmaufnahme in den Systemeinstellungen prüfen: Der Eintrag heißt jetzt „Rekord“. |
| Meeting: Spur „Gegenüber“ bleibt stumm | Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme → unten **Nur Systemaudio** → Rekord an. |
| Meeting: „Claude-Schlüssel fehlt“ | Einstellungen (Zahnrad) → Claude → Schlüssel (`sk-ant-…`) eintragen. Danach ⋯ → „Zusammenfassung neu erstellen“. |
| Meeting: „Transkription braucht macOS 26“ | Die lokale Spracherkennung gibt es erst ab macOS 26. Aufnahme und Ton funktionieren trotzdem. |
| App startet nach dem Update nicht | Weg A: Rekord.zip neu laden und ersetzen. Weg B: `./scripts/install.sh`. Es darf nur eine Rekord.app geben. |

Aufnahmen liegen als `.rekord`-Ordner unter `~/Movies/Rekord`. Ältere Aufnahmen (`.focusrec`, Ordner „Focus Recorder“) zieht die App beim ersten Start automatisch dorthin um und öffnet sie weiter. Aufnahmen werden nie in Git eingecheckt.
