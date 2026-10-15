# Rekord Share

Privater Uploader und öffentlicher Player mit Capability-Links für Rekord. Eigene Implementierung, kein Loom-Code und keine Loom-Assets, keine externen Runtime-Packages.

Für Links, die auch dann funktionieren, wenn der Mac schläft, braucht es einen dauerhaft laufenden Server.

## Lokale Entwicklung

Voraussetzung: Node 22+.

```sh
node --test test/server.test.mjs
node test/local-harness.mjs ../build/share-integration
```

- Das Harness lauscht nur auf Loopback.
- Es schreibt einen zufälligen Token nach `../build/share-integration/connection.json` (Modus 0600). Diese Datei nie veröffentlichen.
- In der Konsole steht nur der Port.

Der macOS-Integrationstest liest die Zugangsdaten intern:

```sh
../scripts/test.sh --integration
../scripts/test.sh --share-integration "$PWD/../build/share-integration/connection.json"
```

**Normaler Start:**
- Umgebungsvariablen setzen: `UPLOAD_TOKEN` (mindestens 32 zufällige Zeichen), `STORAGE_DIR` und eine HTTPS-`PUBLIC_BASE_URL` (ein Pfad wie `/focus-share` ist möglich).
- Dann `node server.mjs` starten. Standard-Bind ist `127.0.0.1:7341`.
- HTTP-Base-URLs werden nur auf Loopback zum Testen akzeptiert.
- Es wird nie automatisch etwas öffentlich deployt.

## Eigenen Server aufsetzen (isoliert)

Auf dem Zielserver ein eigenes Verzeichnis und einen eigenen Hostnamen verwenden. Proxy- oder Speicher-Konfiguration anderer Anwendungen nicht ersetzen.

1. Dieses Verzeichnis auf den Server kopieren.
2. `.env.example` nach `.env` kopieren und Folgendes eintragen:
   - einen frischen, zufälligen Upload-Token,
   - die endgültige HTTPS-Base-URL, z. B. `https://videos.example.com`.

   Den Token mit einem Passwortmanager oder über das SecureField der App handhaben. Er gehört nie in eine Video-URL.
3. `docker compose up -d --build` ausführen.
   - Der Container läuft ohne Rechte und mit read-only Root-Filesystem.
   - Die Medien liegen in einem benannten, persistenten Volume.
   - Der HTTP-Port ist nur auf dem Host-Loopback offen.
4. Eine eigene Reverse-Proxy-Site anlegen (siehe `Caddyfile.example`) und den DNS-Hostnamen auf den Server zeigen lassen. Den vorhandenen Proxy über dessen normalen Ablauf prüfen und neu laden. Caddy holt das TLS-Zertifikat für einen öffentlichen Hostnamen selbst ([Doku zu reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)).
5. In Rekord **Share-Server einrichten** öffnen. HTTPS-Base-URL und Token eintragen (oder die private JSON-Verbindungsdatei importieren) und **Prüfen & speichern** klicken. Die App legt den Token in der macOS Keychain ab.
6. Eine unkritische Testaufnahme hochladen. Den Link von einem anderen Gerät und Netz öffnen, im Video spulen und den Link danach widerrufen. Erst dieser externe Test belegt, dass öffentliche Links funktionieren.

**Grenzen und Kontingente**
- Standard: 2 GiB pro Upload, 20 GiB Gesamtkontingent, höchstens zwei gleichzeitige Uploads.
- Aktive und widerrufene Medien zählen beide zum Kontingent.
- `.env` bewusst passend zu Festplatte und Bandbreite einstellen. Body- und Zeitlimits des Proxys müssen denselben Maximal-Upload erlauben.
- DNS, TLS, persistente Platte, Backup und externe Wiedergabe sind Aufgabe des Deployments. Der lokale Test beweist das nicht.

## Links und Speicherung

- **Zugriff:** Upload, Liste und Widerruf brauchen den Upload-Token als Bearer. Der Token steht nie in einer Abspiel-URL oder HTML-Seite.
- **Wer sehen kann:**
  - Abspiel-IDs haben 192 Bit Zufall.
  - Wer den vollständigen Link hat, kann das Video sehen. Links sind nicht passwortgeschützt.
  - Es gibt keinen öffentlichen Index, keine Analytics und kein Directory-Listing.
  - Die Antworten verbieten Indexierung und fremdes Framing und senden `Referrer-Policy: no-referrer`.
- **Upload:**
  - Uploads werden in eine temporäre `.part`-Datei gestreamt.
  - Vor der Veröffentlichung werden Content-Type, Größe, MP4-Signatur und der optionale SHA-256 geprüft.
  - Halbe Uploads werden nie ausgeliefert. Ihr reserviertes Kontingent wird erst nach dem Aufräumen frei.
  - Die App schickt einen Datei-Hash mit. Ein Retry nach verlorener Erfolgsantwort liefert denselben Link statt einer Kopie. Widerrufene Inhalte lassen sich bewusst neu hochladen und bekommen dann einen neuen Link.
- **Wiedergabe:** Byte-Ranges und HEAD ermöglichen normales Spulen im HTML5-Player. Das MP4 ist für Progressive Playback optimiert.
- **Widerruf:**
  - Ein widerrufener Link verschwindet sofort aus Wiedergabe und Liste. Metadaten und Medien wandern in den privaten Ordner `revoked/`.
  - Bereits heruntergeladene Kopien lassen sich nicht zurückholen.
  - Die App löscht nichts endgültig auf dem Server.
- **Backup:** das komplette Storage-Volume inklusive Metadaten sichern.
  - Wiederherstellen: das passende widerrufene `.json`/`.mp4`-Paar zurück nach `metadata/` bzw. ins Storage-Root verschieben und den Service neu starten.
  - Endgültiges Aufräumen ist ein eigener, bewusster Schritt.
- **Token rotieren:** `.env` ändern, den Service neu erstellen und den Token in der App neu speichern. Bestehende Abspiel-Links bleiben gültig.

## API

| Methode | Pfad | Zugriff | Ergebnis |
|---|---|---|---|
| GET | `/api/status` | Upload-Token | Protokollversion, Limits, freier Speicher |
| POST | `/api/videos` | Upload-Token | Rohes `video/mp4` mit Content-Length, optional `X-Focus-Title` (base64url, UTF-8), `X-Focus-SHA256` und `X-Focus-Expires-Days` (1–3650; danach wird das Video gelöscht und sein Platz frei); liefert ID, Abspiel-URL, Bytezahl und Hash |
| GET | `/api/videos` | Upload-Token | Aktive Videos für die Link-Verwaltung (mit `expiresAt`, falls gesetzt) |
| PATCH | `/api/videos/:id` | Upload-Token | `{"expiresAt": null}` behält den Link dauerhaft, ein ISO-Datum in der Zukunft setzt ein neues Ende |
| DELETE | `/api/videos/:id` | Upload-Token | Widerruf in den wiederherstellbaren privaten Speicher |
| GET/HEAD | `/v/:id` | Capability-Link | Browser-Player |
| GET/HEAD | `/media/:id` | Capability-Link | MP4, auch einzelne Byte-Range-Requests |
| POST | `/api/guides` | Upload-Token | Anleitung als `application/json` (max. 64 MB): `title`, `summary`, `apps`, `steps[]` (`text`, `note`, `warning`, `image` = JPEG als base64), optional `videoId` eines geteilten Videos, `brief` (`summary`, `saving`, `groups[]`), `cta`; liefert ID und Link `/g/:id` |
| GET | `/api/guides` | Upload-Token | Aktive Anleitungen |
| DELETE | `/api/guides/:id` | Upload-Token | Widerruf, Daten wandern nach `revoked/guides/` |
| GET/HEAD | `/g/:id` | Capability-Link | Anleitungs-Seite: hell, mobil lesbar, Schritte mit Bildern (Tippen öffnet groß), Video, Block „Was sich davon automatisieren lässt“, Knopf zur Landingpage (`CTA_URL`, abschaltbar pro Anleitung) |
| GET/HEAD | `/gi/:id/:n.jpg` | Capability-Link | Schritt-Bild (nur geschwärzt hochgeladene JPEGs) |

Die Header heißen `X-Focus-*` und die Protokoll-Kennung `focus-recorder-share`. Das stammt noch aus der Zeit vor der Umbenennung und bleibt so, damit App und laufender Server kompatibel bleiben.

## Was getestet ist

- **Node-Tests:** Authentifizierung, echtes HTTP-Streaming, Prüfsummen und idempotenter Retry, abgebrochene Uploads, Kontingent-Abrechnung, Abwehr von Path-Traversal und ungültigen Ranges, Escaping des Titels, Response-Header, Wiedergabe und Widerruf.
- **Native Tests:** Sie laden ein echtes exportiertes MP4 über URLSession hoch und prüfen Hash, Seite, Spul-Bytes und Widerruf.
- **Lokal im Browser:** Chrome-Wiedergabe und Link-Kopieren geprüft.
- **Öffentlich:** Das gilt erst als belegt, wenn der gewählte Host deployt und von außen getestet ist.

## Bestehender Node/systemd-Host

Docker ist optional. `focus-share.service` startet denselben Server mit dem installierten Node 22+:
- eigener unprivilegierter Account `focus-share`,
- read-only Schutz für System und Home,
- privater Speicher unter `/var/lib/focus-share`,
- `/etc/focus-share.env`, nur für root lesbar.

Den Code in ein unveränderliches Verzeichnis `/opt/focus-share/releases/<version>` installieren und `/opt/focus-share/current` darauf zeigen lassen. Der Service lauscht nur auf Loopback; öffentlich ist allein Caddy.

**Gemeinsamer HTTPS-Hostname**
- Einen eigenen Pfad nutzen, z. B. `PUBLIC_BASE_URL=https://example.com/focus-share`.
- `/focus-share/*` **ohne Abschneiden des Präfixes** proxyen.
- Die Routen der bestehenden App in einen Fallback-`handle` packen, damit deren Authentifizierung weiter jede bestehende Route schützt.
- Der Server legt API, Assets, Player und Medien unter das konfigurierte Präfix.

Das tatsächlich eingerichtete Live-Setup und seine Prüfung stehen in [DEPLOYMENT.md](DEPLOYMENT.md).
