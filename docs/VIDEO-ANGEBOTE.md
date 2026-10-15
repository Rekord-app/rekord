# Video-Angebote

Mit einem Video-Angebot schickst du einen eigenen Link für einen Interessenten. Unter dem Video steht **Termin buchen**. Wenn der Zuschauer zustimmt, siehst du in Rekord die gemessenen Öffnungen, abgespielten Abschnitte und Klicks auf den Terminbutton.

## Angebot erstellen

1. Aufnahme im Editor öffnen und im Teilen-Menü **Als Video-Angebot teilen** wählen. Rekord bereitet das Video vor. Für bereits hochgeladene Videos geht es auch über **Freigaben verwalten → Angebot**.
2. **Empfänger (nur intern)** ausfüllen, etwa „Beispielagentur“. Diese Beschriftung sieht der Zuschauer nicht. Öffentlichen Titel, optional eine Nachricht und den vollständigen HTTPS-Buchungslink eintragen.
3. Entscheiden, ob Rekord Wiedergabe-Statistik anfragen und bei der ersten gemessenen Öffnung benachrichtigen soll.
4. **Angebotslink erstellen** kopiert den fertigen Link. **Vorschau** öffnet eine 15 Minuten gültige Ansicht ohne Messung. **Weiterer Empfänger** erzeugt einen weiteren, getrennten Link für dieselbe Videodatei.

Ein fehlgeschlagener Versuch lässt sich wiederholen. Solange du seine Felder nicht veränderst, entsteht dabei kein doppelter Angebotslink. Den Standard-Buchungslink und macOS-Mitteilungen findest du unter **Einstellungen → Teilen → Video-Angebote**. Eine Änderung des Standards verändert bereits erstellte Angebote nicht.

## Was Zuschauer sehen

Video und Terminbutton funktionieren ohne Konto und ohne Zustimmung zur Statistik. **Statistik erlauben** startet die Messung ab diesem Zeitpunkt. **Ohne Statistik ansehen** erzeugt keine Mess-Session. **Statistik widerrufen** beendet sie und löscht ihre bereits gespeicherten Messdaten. Schlägt das Löschen wegen einer Verbindungsstörung fehl, werden keine weiteren Werte gesendet; der Button bietet einen erneuten Löschversuch.

Es gibt keine Drittanbieter-Tracker, Tracking-Cookies oder geräteübergreifende Zuschauer-ID. Eine zugelassene Session kann im selben Tab nach Neuladen fortgesetzt werden; nach 30 Minuten Inaktivität endet ihre Berechtigung. Ohne JavaScript bleiben Video und Buchungslink verfügbar.

## Auswertung und Mitteilungen

Öffne **Video-Angebote** in der Seitenleiste oder über **Freigaben verwalten**. Die Daten kommen vom Server, auch wenn das lokale Aufnahmeprojekt inzwischen entfernt wurde.

| Anzeige | Bedeutung |
|---|---|
| Noch keine gemessene Aktivität | Keine zugelassene Messung eingegangen. Das beweist nicht, dass der Link nie geöffnet wurde. |
| Öffnungen | Anzahl zugelassener Mess-Sessions. Seitenabruf, HEAD, Download und Linkvorschau zählen nicht. |
| Wiedergaben gestartet | Sessions mit tatsächlich gemessenem Wiedergabefortschritt. |
| Beste Wiedergabe | Höchster abgespielter Anteil einer einzelnen Session. Verschiedene Zuschauer werden nicht zusammengerechnet. |
| Zuletzt abgespielt bis | Letzter gemessener Video-Zeitpunkt; unabhängig vom abgespielten Anteil. |
| Terminbutton geklickt | Klicks während zugelassener Sessions. Eine Buchung wird nicht bestätigt. |

30 abgespielte Sekunden eines zweiminütigen Videos ergeben 25 %. Wiederholungen desselben Abschnitts erhöhen diesen Anteil nicht. Vorspulen zählt keine übersprungenen Abschnitte. Gemessen wird Wiedergabe, keine Aufmerksamkeit; Hintergrundwiedergabe kann enthalten sein. Netzverlust oder Browserabbruch können den letzten noch unbestätigten Abschnitt verlieren. Clientseitige Werte sind keine manipulationssicheren Nachweise.

Die Zuordnung erfolgt **über den Link**, nicht über eine verifizierte Person. Weiterleitungen können zusätzliche Sessions erzeugen.

Die laufende App aktualisiert etwa alle 15 Sekunden. Bei Fehlern wartet sie schrittweise bis zu fünf Minuten; Aufwachen und manuelles Aktualisieren lösen einen neuen Abruf aus. Pro Angebotslink gibt es eine erste Öffnungsaktivität. Lokale macOS-Banner brauchen Systemfreigabe und aktivierte Mitteilungen. Bei beendeter App oder schlafendem Mac erfolgt keine sofortige Meldung: Die gespeicherte Aktivität erscheint beim nächsten Abruf. Mehrere neue Ereignisse werden zusammengefasst. Die erste Einrichtung schickt keine rückwirkenden Banner für alte Aktivität. Es werden keine E-Mails versendet.

## Bearbeiten, Ablauf und Löschen

- Titel, Nachricht, Buchungslink und Schalter lassen sich ohne neuen Upload bearbeiten.
- **Laufzeit ändern** passt den Angebotslink an. Er kann höchstens so lange verfügbar sein wie das Video. Unter den geteilten Aufnahmen macht **Behalten** zunächst das Video dauerhaft.
- **Angebotslink deaktivieren** sperrt dessen Seite, Medienroute und Messung. Andere Angebote desselben Videos bleiben bestehen.
- **Video deaktivieren** sperrt auch alle zugehörigen Angebote. Ein zuvor separat versendeter normaler Videolink bleibt sonst ein eigener Zugang.
- **Statistik löschen** entfernt Sessions und Öffnungsaktivität und startet eine neue Messgeneration. Alte Session-Berechtigungen bleiben ungültig. Video und Link bleiben verfügbar.
- Messdaten und daraus berechnete Summen bleiben standardmäßig höchstens 90 Tage erhalten. Deaktivierte Angebotsmetadaten einschließlich interner Beschriftung werden nach 90 Tagen entfernt. Bereits angezeigte macOS-Mitteilungen und heruntergeladene Videos können nicht zurückgeholt werden.

## Für Betreiber

Server und App verwenden weiterhin Protokollversion 1. Die Feature-Werte `video-offers-v1` und `video-analytics-v1` kennzeichnen die Erweiterung. Normales Teilen funktioniert auch mit älteren Servern; dort zeigt Rekord den fehlenden Angebots-Support an.

`OPERATOR_NAME` und `PRIVACY_URL` konfigurieren Betreiberangabe und Datenschutzlink. Der Betreiber legt die passenden Informationen fest. `OFFERS_ENABLED=false` stoppt neue Angebote und Messung, lässt vorhandene Seiten, Medien und Terminbuttons verfügbar.

Die privaten Ordner `offers/` und `analytics/` gehören ins gesicherte Storage-Volume. Zugriff auf Verwaltung und Statistik benötigt den Upload-Schlüssel. Der Dienst ist für einen Betreiber und einen Node-Prozess ausgelegt; mehrere Writer auf demselben Speicher werden nicht unterstützt. API, Limits und Startkonfiguration stehen in [share-service/README.md](../share-service/README.md).
