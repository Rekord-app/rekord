# Datenschutz in Rekord

Rekord speichert Projekte standardmäßig unter `~/Movies/Rekord/`. Die App ist kein Nachweis der Zustimmung anderer Personen. Kläre Aufnahmen vorher mit den Beteiligten.

| Funktion | Lokal | Externe Übertragung |
|---|---|---|
| Studio | Bildschirmvideo, Mikrofon, Kamera, Mausdaten, Schnitt und Export | Erst beim ausdrücklich gewählten Teilen: exportiertes Video an deinen Share-Server |
| Meetings | Mikrofon/Systemton, lokales Transkript, Notizen | Mit eingerichtetem Claude-Schlüssel: Transkript, Namen und Glossarbegriffe an Anthropic für die Zusammenfassung |
| Anleitungen | vollständige Aufnahme, Interaktionen, lokale Spracherkennung, OCR, bearbeitete Bilder | KI-Texte/Brief: maskierte Texte an Anthropic. Teilen: Titel, Texte, Apps, aktuelle geschwärzte Schritt-JPEGs, optional Brief und stabile Anleitungs-ID an deinen Server. Kein Rohvideo oder Audio |
| Arbeits-Inventur (experimentell) | lokale Proben, Bilder, Arbeitsblöcke, Antworten | Maskierter Text an Anthropic zur Auswertung. Keine Inventur-Bilder oder Audios an den Share-Server |
| Video-Angebote | Standard-Buchungslink und Mitteilungscursor; Statistik wird vom Server geladen | Titel, Nachricht, interne Empfängerbeschriftung und Buchungslink an deinen Server. Erst nach Zuschauer-Zustimmung: Session, Öffnungszeit, abgespielte Bereiche und CTA-Klicks. Kein Empfänger-Login und keine bestätigte Buchung |
| MCP | Zugriff auf lokale Rekord-Dateien und Steuerung durch deinen verbundenen MCP-Client | Was dein MCP-Client an seinen Anbieter sendet, richtet sich nach dessen Konfiguration. Vor Anschluss prüfen |

Die lokale Spracherkennung benötigt macOS 26 und ggf. einen einmaligen Download des Sprachmodells von Apple. Bildschirm, Mikrofon, Kamera, Systemton und Bedienungshilfen werden über macOS-Freigaben gesteuert. API-Schlüssel und Upload-Token werden im macOS-Schlüsselbund gespeichert.

Automatische Schwärzung ist Mustererkennung und kann vertrauliche Daten übersehen. Prüfe Bilder, Texte und Brief vor jedem Upload. Manuelle Schwärzungen bleiben bearbeitbar; Anleitungsbilder werden beim Teilen aus dem Video neu erzeugt. Ein bereits veröffentlichter Link ändert sich durch lokale Bearbeitung nicht. Zum Entfernen alter Fassungen deren Freigaben deaktivieren.

Capability-Links sind für jeden mit der URL erreichbar und können weitergegeben werden. Es gibt keinen Empfänger-Login. Widerruf sperrt die Serverauslieferung aller verbundenen Revisionen und alten Videos; heruntergeladene Kopien bleiben beim Empfänger. Widerrufene Dateien verbleiben im privaten Serverspeicher und im Backup bis zur bewussten Löschung durch den Betreiber. Ablaufende Videolinks werden nach Ablauf endgültig entfernt. Lokales Löschen widerruft keine Links.

Inventur-Aufbewahrung: Bilder standardmäßig 7 Tage, Rohproben 30 Tage; Einstellungen und Ausschlüsse prüfen. Einzelheiten: [Inventur-Datenschutz](inventur-datenschutz.md). Lokale Projekte können über den Papierkorb gelöscht werden. Eigene Backups, iCloud/andere synchronisierte Ordner und Server-/Proxy-Protokolle haben ihre eigene Aufbewahrung.

Die App ist kostenlos. Claude-API, Serverbetrieb und Datenverkehr können Kosten verursachen. Die Datennutzung externer Anbieter richtet sich nach deinen Verträgen und Einstellungen; Rekord verspricht keine anbieterübergreifende Löschung.

Video-Angebote behalten Messdaten standardmäßig höchstens 90 Tage; Widerruf/Ablauf entfernt sie früher. Statistik lässt sich separat löschen. Einzelne Angebotslinks sind getrennt deaktivierbar, verknüpfte Medien-/Anleitungswiderrufe sperren alle betroffenen Angebote. Lokale Öffnungsmitteilungen benötigen die laufende App und macOS-Freigabe. [Details und Zuschauer-Auswahl](VIDEO-ANGEBOTE.md).
