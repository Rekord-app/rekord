# Arbeits-Inventur: Daten und Team-Nutzung

Die Inventur soll wiederkehrende Arbeit verständlich machen. Sie ist kein Werkzeug zur heimlichen Mitarbeiterkontrolle. Sie startet erst durch dich; im Team-Modus zusätzlich nach deiner eigenen Bestätigung. Während sie läuft, bleibt das Menüleisten-Symbol sichtbar. Du kannst ohne Begründung jederzeit pausieren oder stoppen.

## Was lokal erfasst wird

Alle fünf Sekunden: App, Bundle-ID, Fenstertitel, URL ohne Query/Zugangsdaten/Fragment sowie Rolle und Beschriftung des fokussierten Elements. Bei Kontextwechsel oder nach 30 Sekunden wird, soweit die Freigaben und ein vollständig lesbarer Elementbaum vorliegen, das fokussierte Fenster lokal erfasst. Andere Fenster bleiben außen vor. Das Bild wird auf höchstens 1280 Pixel verkleinert. Erkannte Eingabefelder werden vor der Texterkennung abgedeckt, sensible Textmuster vor Speicherung maskiert. Bei Fokus in einem Eingabefeld pausiert die Inventur.

Keine Tastaturüberwachung. Ohne Bedienungshilfen nur App-Metadaten, keine Fensterbilder: Private-Fenster und Eingabefelder ließen sich sonst nicht ausreichend erkennen. Ohne Bildschirmfreigabe bleiben nur die zugänglichen Metadaten. Die Maskierung erkennt bestimmte Muster (E-Mail, IBAN, Telefon, Karten mit Prüfziffer, Passwortpunkte), nicht jede denkbare vertrauliche Angabe. Ausschlüsse vor Nutzung prüfen; nicht zuverlässig erkennbare Apps ganz ausschließen. Namen, Projekttitel und sonstige vertrauliche Texte können trotz Maskierung enthalten sein.

Pause bei mehr als zwei Minuten Leerlauf, gesperrtem Bildschirm, erkannter Telefon-/Videokonferenz, laufender Aufnahme, manuell gewählter Pause, ausgeschlossenen Apps und erkannten Privat-/Inkognito-/InPrivate-Fenstern. Standardausschlüsse: Rekord, Passwort-Manager, Schlüsselbund, Nachrichten, WhatsApp, Signal und bekannte Banking-Apps. Die Liste ist erweiterbar; neue Banking-Apps/Domains sind nicht automatisch vollständig bekannt. Private-Fenster-Erkennung ist titel-/subrollenbasiert und braucht eine Prüfung je Browser.

## Was den Mac verlässt

Nur maskierter Text an `https://api.anthropic.com/v1/messages`: Kontextausschnitte, Blockbeschreibungen, gesprochene oder getippte Antworten und Prozessbeschreibungen. Kein Screenshot, Ton oder Video. Lokale Spracherkennung kann Apple-Sprachmodelle beim ersten Gebrauch herunterladen; Testläufe setzen vorhandene Sprachmodelle voraus. Der Auswertungstransport verwendet ausschließlich die Anthropic-API. `usage.json` enthält tatsächliche Input-/Output-Tokens und Request-Bytes. Der Katalog und Übergaben werden ebenfalls lokal gespeichert.

Standardbudget: 400.000 Tokens/Tag. Vor Anfragen wird eine konservative Reserve geprüft; tatsächliche Nutzung wird auch bei fehlerhafter strukturierter Antwort gespeichert. Bei ausgeschöpftem Budget läuft die lokale Erfassung weiter. Netzwerkfehler nach Annahme einer Anfrage können beim Anbieter Kosten verursachen, obwohl keine Nutzungsantwort angekommen ist. Gemessene Fixture-Werte stehen im [Abnahmebericht](validation/inventory/acceptance.md); sie sind kein Preisversprechen für reale Arbeitstage.

Es gibt **keinen Inventur-Upload an den Rekord-Share-Server**. Der lokale MCP-Server kann die eigenen Daten lesen. `include_snapshots` liefert nur lokale Pfade und ist standardmäßig aus. Wer einem externen Agenten Zugriff auf den Mac oder MCP gibt, muss dessen eigene Datenverarbeitung berücksichtigen.

## Ablage und Löschung

`~/Movies/Rekord/Inventur/YYYY-MM-DD/`: `samples.jsonl`, `snapshots/`, `blocks.json`, `checkins.json`, `usage.json`. Katalog: `prozesse.json/.md`; Übergaben: `Prozesse/<ID>/handover.json/.md`. Standardmäßig werden Bilder aus Tagen älter als sieben Tage und Rohproben aus Tagen älter als 30 Tage entfernt. Aufräumen erfolgt beim Start und am Tageswechsel; kein Hintergrunddienst bei beendeter App. Fristen sind einstellbar.

Blöcke, Rückfragen und Katalog bleiben bis zur eigenen Löschung. Ein Block lässt sich in der Tagesansicht löschen; dazugehörige Proben, Bilder und Antworten sowie betroffene Übergabepakete werden entfernt. „Inventur-Bilder jetzt löschen“ entfernt sämtliche lokalen Inventur-Bilder. Für eine vollständige Löschung: Inventur stoppen und den Inventur-Ordner löschen; externe Kopien/Backups getrennt behandeln. Die Aufnahmen-Aufbewahrung von Studio/Loom greift nicht auf Inventur zu.

## Team-Freigabe

Die Mitarbeiterin oder der Mitarbeiter sieht den Katalog zuerst. Name, Beschreibung und Schritte können vor dem Export geändert werden; danach muss der Prozess erneut abgehakt werden. Neu ausgewertete Kataloge verlieren alte Freigaben. Der lokale Export `.json`/`.md` enthält nur abgehakte Prozesse mit Beschreibung, Schritten, Werkzeugen, Bewertung und hochgerechneten Kennzahlen. Keine Zeitachse, Rohproben, Bilder, Block-IDs oder wörtlichen Rückfrage-Antworten. Kein automatischer Versand an Arbeitgeber. Texte trotzdem vor Weitergabe auf vertrauliche Inhalte prüfen.

## Einordnung für Unternehmen

Vor Einführung Zweck, Rechtsgrundlage, Transparenz, Zugriff und Löschfristen mit dem zuständigen Datenschutzverantwortlichen klären. Eine App-Bestätigung allein begründet keine rechtliche Zulässigkeit im Beschäftigungsverhältnis. Die DSGVO verlangt unter anderem Zweckbindung und Datenminimierung; Auskunft, Berichtigung und Löschung sind zu berücksichtigen. [BMJV zur DSGVO](https://www.bmj.de/DE/themen/digitales/digitale_kommunikation/dsgvo/dsgvo_node.html).

Bei einem Betriebsrat kann § 87 Abs. 1 Nr. 6 BetrVG einschlägig sein: Einführung und Nutzung technischer Einrichtungen zur Verhaltens-/Leistungsüberwachung unterliegen der Mitbestimmung. Den konkreten Einsatz vorab klären. [Gesetzestext § 87 BetrVG](https://www.gesetze-im-internet.de/betrvg/__87.html). Das ist eine technische Beschreibung mit rechtlichen Hinweisen, keine Rechtsberatung oder Zusicherung „DSGVO-konform“.

## Information für Mitarbeiter (Vorlage)

1. Mit Rekord kannst du wiederkehrende Aufgaben in deinem Arbeitsalltag erkennen.
2. Du entscheidest selbst, wann du die Inventur startest und pausierst.
3. Das Symbol in der Menüleiste zeigt dir, ob sie läuft.
4. Erfasst werden Apps, Fensterkontext und lokal erkannter, maskierter Text.
5. Bilder bleiben auf deinem Mac; maskierter Text geht zur Auswertung an Anthropic.
6. Private Fenster und ausgeschlossene Apps sollen nicht erfasst werden; prüfe die Ausschlüsse mit uns.
7. Bilder werden nach sieben, Rohproben nach 30 Tagen gelöscht; die Fristen kannst du ändern.
8. Du siehst deine Prozess-Liste zuerst und kannst Texte ändern oder Prozesse löschen.
9. Nur einzeln von dir freigegebene Prozesse exportierst du für das Unternehmen.
10. Ansprechpartner, Zweck und betriebliche Vereinbarung: [hier vor dem Einsatz ergänzen].
