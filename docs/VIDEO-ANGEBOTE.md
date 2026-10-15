# Video-Angebote

Mit einem Video-Angebot schickst du einen eigenen Link für einen Interessenten. Unter dem Video steht **Termin buchen**. Bei neuen Angeboten startet die Statistik automatisch: Du siehst in Rekord die gemessenen Öffnungen, abgespielten Abschnitte und Klicks auf den Terminbutton.

## Angebot erstellen

1. In der Seitenleiste **Video-Angebote → Buchungslink & Landingpage** öffnen. Standard-Buchungslink, Absender/Firma, Farbe, Button-Text und optional eine Standardnachricht eintragen. **Vorlage speichern** prüft den HTTPS-Link. Ein schon hinterlegter Standard-Buchungslink wird übernommen.
2. Aufnahme im Editor öffnen und im Teilen-Menü **Als Video-Angebot teilen** wählen. Ohne gültige Vorlage öffnet Rekord die Einrichtung vor Export und Upload und setzt nach dem Speichern fort. Für bereits hochgeladene Videos geht es auch über **Freigaben verwalten → Angebot**.
3. **Empfänger (nur intern)** ausfüllen, etwa „Beispielagentur“. Diese Beschriftung sieht der Zuschauer nicht. Titel, Nachricht und Buchungslink lassen sich pro Angebot anpassen. Statistik und erste Öffnungsmeldung sind bereits aktiv, ohne ein Häkchen setzen zu müssen.
4. **Angebotslink erstellen** kopiert den fertigen Link. **Vorschau** öffnet eine 15 Minuten gültige Ansicht ohne Messung. **Weiterer Empfänger** erzeugt einen weiteren, getrennten Link für dieselbe Videodatei.

Unter **Landingpage und Statistik anpassen** kannst du Gestaltung, Messmodus und Mitteilungen für ein einzelnes Angebot ändern. Die Standardvorlage wird als Kopie übernommen; spätere Änderungen daran verändern bereits verschickte Angebote nicht. Der Standardlink ist auch unter **Per Link teilen → Video-Angebote** erreichbar. Ein fehlgeschlagener Versuch mit unveränderten Feldern erzeugt beim Wiederholen keinen doppelten Link.

## Was Zuschauer sehen

Video und Terminbutton funktionieren ohne Konto. Bei neuen Angeboten beginnt die Messung, sobald die Seite sichtbar ist. Ein sichtbarer Hinweis erklärt die erfassten Daten. **Statistik ausschalten** beendet sie und löscht diese Session. Schlägt das Löschen fehl, werden keine weiteren Werte gesendet; der Button bietet einen erneuten Löschversuch. Die Ausschaltentscheidung wird für diesen Link im selben Tab gemerkt. Browser-Signale Global Privacy Control und Do Not Track werden berücksichtigt.

Die automatische Messung nutzt keine Cookies, Drittanbieter-Tracker oder dauerhafte Zuschauer-ID. Ihre Session bleibt nur im Arbeitsspeicher der Seite. Neuladen zählt deshalb als neue Öffnung; die Zahl entspricht nicht der Anzahl verschiedener Personen. Erst beim Ausschalten wird die Präferenz im Session-Speicher des Tabs gespeichert. Ohne JavaScript bleiben Video und Buchungslink verfügbar, es entsteht keine Statistik.

Ältere Angebote behalten ihren Modus **Nach Zustimmung**: Dort startet **Statistik erlauben** die Messung, und eine zugelassene Session kann im selben Tab nach Neuladen fortgesetzt werden. Der Modus lässt sich unter **Bearbeiten → Landingpage und Statistik anpassen** umstellen. Alte Angebote ohne Vorlagenfelder behalten die Rekord-Gestaltung.

## Auswertung und Mitteilungen

Öffne **Video-Angebote** in der Seitenleiste oder über **Freigaben verwalten**. Die Daten kommen vom Server, auch wenn das lokale Aufnahmeprojekt inzwischen entfernt wurde.

| Anzeige | Bedeutung |
|---|---|
| Noch keine gemessene Aktivität | Keine Messung eingegangen. Das beweist nicht, dass der Link nie geöffnet wurde. |
| Öffnungen | Anzahl gemessener Seitenöffnungen (Sessions). Seitenabruf, HEAD, Download und Linkvorschau zählen nicht. |
| Wiedergaben gestartet | Sessions mit tatsächlich gemessenem Wiedergabefortschritt. |
| Beste Wiedergabe | Höchster abgespielter Anteil einer einzelnen Session. Verschiedene Zuschauer werden nicht zusammengerechnet. |
| Zuletzt abgespielt bis | Letzter gemessener Video-Zeitpunkt; unabhängig vom abgespielten Anteil. |
| Terminbutton geklickt | Klicks während aktiver Mess-Sessions. Eine Buchung wird nicht bestätigt. |

30 abgespielte Sekunden eines zweiminütigen Videos ergeben 25 %. Wiederholungen desselben Abschnitts erhöhen diesen Anteil nicht. Vorspulen zählt keine übersprungenen Abschnitte. Gemessen wird Wiedergabe, keine Aufmerksamkeit; Hintergrundwiedergabe kann enthalten sein. Netzverlust oder Browserabbruch können den letzten noch unbestätigten Abschnitt verlieren. Clientseitige Werte sind keine manipulationssicheren Nachweise.

Die Zuordnung erfolgt **über den Link**, nicht über eine verifizierte Person. Weiterleitungen können zusätzliche Sessions erzeugen.

Die laufende App aktualisiert etwa alle 15 Sekunden. Bei Fehlern wartet sie schrittweise bis zu fünf Minuten; Aufwachen und manuelles Aktualisieren lösen einen neuen Abruf aus. Pro Angebotslink gibt es eine erste Öffnungsaktivität. Lokale macOS-Banner brauchen Systemfreigabe und aktivierte Mitteilungen. Bei beendeter App oder schlafendem Mac erfolgt keine sofortige Meldung: Die gespeicherte Aktivität erscheint beim nächsten Abruf. Mehrere neue Ereignisse werden zusammengefasst. Die erste Einrichtung schickt keine rückwirkenden Banner für alte Aktivität. Es werden keine E-Mails versendet.

## Bearbeiten, Ablauf und Löschen

- Titel, Nachricht, Buchungslink, Landingpage und Messmodus lassen sich ohne neuen Upload bearbeiten.
- **Laufzeit ändern** passt den Angebotslink an. Er kann höchstens so lange verfügbar sein wie das Video. Unter den geteilten Aufnahmen macht **Behalten** zunächst das Video dauerhaft.
- **Angebotslink deaktivieren** sperrt dessen Seite, Medienroute und Messung. Andere Angebote desselben Videos bleiben bestehen.
- **Video deaktivieren** sperrt auch alle zugehörigen Angebote. Ein zuvor separat versendeter normaler Videolink bleibt sonst ein eigener Zugang.
- **Statistik löschen** entfernt Sessions und Öffnungsaktivität und startet eine neue Messgeneration. Alte Session-Berechtigungen bleiben ungültig. Video und Link bleiben verfügbar.
- Messdaten und daraus berechnete Summen bleiben standardmäßig höchstens 90 Tage erhalten. Deaktivierte Angebotsmetadaten einschließlich interner Beschriftung werden nach 90 Tagen entfernt. Bereits angezeigte macOS-Mitteilungen und heruntergeladene Videos können nicht zurückgeholt werden.

## Für Betreiber

Server und App verwenden weiterhin Protokollversion 1. Zusätzlich zu `video-offers-v1` und `video-analytics-v1` benötigt die neue Einrichtung `video-offer-templates-v1` und `video-analytics-automatic-v1`. Zuerst den Server aktualisieren. Die App meldet fehlende Unterstützung vor einem Angebotsupload. Normales Teilen funktioniert auch mit älteren Servern; dort zeigt Rekord den fehlenden Angebots-Support an.

`OPERATOR_NAME` und `PRIVACY_URL` konfigurieren Betreiberangabe und Datenschutzlink. Der Betreiber legt die passenden Informationen fest. `OFFERS_ENABLED=false` stoppt neue Angebote und Messung, lässt vorhandene Seiten, Medien und Terminbuttons verfügbar.

Die privaten Ordner `offers/` und `analytics/` gehören ins gesicherte Storage-Volume. Zugriff auf Verwaltung und Statistik benötigt den Upload-Schlüssel. Der Dienst ist für einen Betreiber und einen Node-Prozess ausgelegt; mehrere Writer auf demselben Speicher werden nicht unterstützt. API, Limits und Startkonfiguration stehen in [share-service/README.md](../share-service/README.md).
