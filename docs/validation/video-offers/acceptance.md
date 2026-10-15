# Video-Angebote · Abnahme 15.10.2026

Version 1.9.0, Build 11. Ausschließlich synthetische Medien und Empfänger. Keine echte Aufnahme veröffentlicht, keine Nachricht an Interessenten versendet und kein Termin gebucht.

## Geprüft

- **30/30 Node-Testgruppen:** Angebots-CRUD, idempotente Erstellung, interne Felder, URL-/HTML-Validierung, Vorschau, Prefix, Widerruf und Ablauf. Analytics: Zustimmung, Ursprung, getrennte Sessions, Intervallvereinigung, Sequenzen, Neustart, Löschung, Quarantäne, Aufbewahrung, Mengen-/Request-Limits. Dazu die unveränderten Video- und erweiterten Anleitungs-Regressionen.
- Lastprobe: 20 gleichzeitige Sessions und fortgesetzte Medien-Ranges unter einem systemd-Limit von 384 MiB; Spitzen-RSS 88.720 KiB, kein Swap, Exit 0.
- Core und Medien: eigener Swift-Test-Runner, 1080p60/4K, Audio, Abbruch, Vorschau-/Exportvergleich und bestehende Kernfunktionen.
- Native URLSession: Upload, zwei getrennte Angebote, Retry, Zustimmung, Statistik und Aktivität, Vorschau, Bearbeiten, Laufzeit, Statistiklöschung und Widerruf. Manipulierte Angebots-URLs mit falschem Port, Schema, Pfad, Zugangsdaten, Query oder Fragment werden abgewiesen. Alter Server wird erkannt.
- Native App: erste gemessene Öffnung nach 15 Sekunden, Aktivität nach neu erzeugtem Store vorhanden, Mitteilungsklick vor/nach Store-Anbindung und Meeting-Navigation. Formular und Auswertung als echte SwiftUI-Views gerendert.
- Chrome und WebKit: Wiedergabe mit synthetischem 120-Sekunden-MP4, vor Zustimmung/Ablehnung keine Messrequests; 30 Sekunden ≈25 %, Wiederholung bleibt ≈25 %, anderer Abschnitt ≈50 %, 10+5 Sekunden nach Seek ≈12,55 %. Pause, Reload, CTA-Klick, Widerruf, Tastatur, Ansicht bei 390 px ohne horizontales Scrollen und Video/CTA ohne JavaScript.
- MCP: bestehende Video-/Inventur-Werkzeuge und Eingabe-/Dateischutz bestehen. Neue Angebots-MCP-Werkzeuge gehören nicht zu diesem Release.
- Release: optimierter App-/MCP-Build, lokale Signatur und Bundle-Prüfung. Öffentliche GitHub-Veröffentlichung ist ein separater Auftrag.
- GitHub-CI auf Commit `13fae77` vollständig bestanden: Node 22/24 sowie macOS 26 mit Release-Build, Core-, Medien-, MCP-, Public-Export- und Release-Guard-Prüfungen. [CI-Lauf](https://github.com/Rekord-app/rekord-dev/actions/runs/38743482596).
- Öffentlicher HTTPS-Server: Chrome misst 25,01789 % des 120-Sekunden-Testvideos; Vorschau zählt nicht, Widerruf sperrt Seite und Stream. Die native URLSession-Abnahme besteht einschließlich Angebots-, Video- und Anleitungsablauf. [Öffentlicher Browserbericht](public-report.json).
- Betrieb: alle zehn zuvor vorhandenen Freigaben erhalten; Backup mit 58 dateiweisen Prüfsummen wiederhergestellt und vom neuen Server eingelesen. Feature-Schalter und Rückwechsel auf einen Vorgänger mit `guide-lifecycle-v2` an isolierten Testdaten geprüft; Wiederaktualisierung erhält Angebotsstatistik.
- Installierte App: 1.9.0 (11) unter `~/Applications/Rekord.app`, Signatur und laufender Prozesspfad geprüft. Ein bereits hochgeladenes synthetisches Video über das echte Formular in **8,907 Sekunden** als Angebot erstellt (automatisierte Bedienung, kein menschlicher Geschwindigkeitstest), Empfängerbeschriftung und Buchungslink serverseitig bestätigt und in der nativen Auswertung angezeigt. Testvideo und zugehöriges Angebot danach widerrufen; Seite und Stream 404. [Installationsbericht](installed-report.json).

## Tatsächlicher Auslieferungsstand

Der zusammengeführte Server ist live. Die lokal signierte App 1.9.0 (11) wurde nach regulärem Ende der Meeting-Aufnahme und abgeschlossener Verarbeitung installiert und abgenommen; die Aufnahme wurde nicht unterbrochen. Anschließend wurde durch den parallelen Bibliotheksauftrag **1.10.0 (12)** installiert. Die Angebotsimplementierung ist darin unverändert enthalten; Signatur und Einstieg in die Angebotsverwaltung wurden auch in dieser aktuellen App geprüft. Die vollständige Feature-Abnahme oben bezieht sich auf 1.9.0. Die technische Abnahme ersetzt keine Nutzerprüfung mit eigenem Buchungslink. OS-Aufgabe #218 hält diesen Test fest; #219 (Installation) ist erledigt.

## Zusammenspiel mit der Launch-Härtung

Die parallele Erweiterung `guide-lifecycle-v2` ist enthalten. Dauerhafte Widerrufsvermerke und die Sperre während eines laufenden Anleitungsuploads bleiben erhalten. Wird eine alte Anleitung mit verknüpftem Video widerrufen, werden auch alle Angebote dieses Videos samt Messdaten gesperrt. Ein eigener Regressionstest prüft das über einen Neustart hinweg.

## Grenzen

- Ein physisches iPhone wurde nicht getestet; die mobile Ansicht wurde in Chrome und WebKit bei 390 px geprüft.
- Ein persönlicher Link ist kein Identitätsnachweis. Abgespielte Abschnitte beweisen keine Aufmerksamkeit, ein CTA-Klick keine Buchung.
- Die App muss für zeitnahe lokale Mitteilungen laufen. Ohne macOS-Mitteilungsfreigabe bleibt die Aktivität in Rekord verfügbar. Auf diesem Mac fehlt die Systemfreigabe; deshalb wurde kein Banner ausgelöst. Die Aktivitätsabfrage und Navigation sind geprüft. [Nativer Bericht](native-report.txt).
- Die lokale Signatur ist keine Developer-ID-Notarisierung. Die separate Distributionsabnahme gehört zum Launch-Prozess.
- Backups brauchen eine Betreiber-Aufbewahrung; ein Restore kann ansonsten zuvor gelöschte Daten zurückbringen. Die Anwendung verspricht keine automatische Löschung externer Sicherungskopien.

## Wiederholen

`npm test` im Share-Service; `scripts/test.sh --integration`, `--share-integration <private connection.json>` und `--mcp` im Repository. Browserabnahme über `share-service/test/browser-acceptance.mjs`; Playwright ist eine optionale Testabhängigkeit. Die nativen Angebotsdiagnosen verlangen explizit einen Loopback-Server und synthetische Medien.

Screenshots: [Formular](native-form.png), [Auswertung](native-offers.png), [Chrome mobil](chrome-mobile.png), [WebKit mobil](webkit-mobile.png).
