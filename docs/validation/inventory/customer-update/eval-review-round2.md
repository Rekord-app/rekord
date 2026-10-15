# Unabhängige Eval-Prüfung — Runde 2

Prüfdatum: 2026-10-15. Separater Codex-Prüfagent, ohne vorgegebene Wunsch-Scores. Grundlage: `rubric.md`, aktuelle `eval-cases.json`, `eval-runs.json`, `customer_update.py`, `run_evals.py`, `process-from-mcp.json` einschließlich Übergabe-Paket sowie alle gespeicherten Ein-/Ausgaben und `.eml`-Dateien in `runs/`. Der Workspace-Skill `prozess-automatisieren` wurde berücksichtigt.

## Urteil

**9,80/10 für die zehn vorliegenden Fälle; keine harten Fehler in diesen Läufen.** Der lokale, auf Abruf erzeugte Entwurf erreicht die technische Eval-Schwelle. Diese Bewertung gilt für strukturierte, manuell zusammengestellte Eingaben und frische Ausgabepfade. Sie belegt weder einen Entwurf im echten Postfach noch eine bereits erfolgte menschliche Prüfung.

Gegenüber Runde 1 sind die inhaltsleeren Berichte beseitigt, die JSON-Wurzel wird geprüft, Laufmetadaten sind vorhanden und erfolgreiche Läufe erzeugen zusätzlich eine ungesendete lokale E-Mail-Datei. Eine neue relevante Grenze ist die Wiederverwendung eines Ausgabepfads: Nach einem erfolgreichen Lauf bleibt dessen alte `.eml` bei einem anschließenden `needs_input` bestehen. Bis dies behoben ist, muss jeder Aufruf einen frischen Ausgabeordner verwenden und den JSON-Status auswerten.

## Prüfung der tatsächlichen Artefakte

Alle zehn gespeicherten CLI-Läufe weisen Exit-Code 0 und leeres stderr aus. Die Fall-IDs, Einzeldateien und Testeingaben stimmen überein. Alle erwarteten Status, Fakten, untersagten Aussagen und Eindeutigkeitsbedingungen sind erfüllt. Jeder protokollierte Skript-Hash entspricht dem gelesenen Skript; alle Läufe nennen Python 3.12.10 und einen UTC-Abschlusszeitpunkt zwischen 11:47:15.992259 und 11:47:16.066165 am 2026-10-15. Der Runner begrenzt parallele Prozesse auf drei.

Zusätzlich wurde `main()` unverändert mit im Speicher ersetzten Dateizugriffen erneut für alle zehn Eingaben ausgeführt. Die JSON-Ergebnisse stimmen überein; lediglich der temporäre Dateiname der Speicherprüfung wurde vor dem Vergleich auf den gespeicherten Namen normalisiert. Die erzeugten E-Mail-Bytes stimmen ohne Normalisierung exakt mit den fünf vorhandenen `.eml`-Dateien überein. Die ursprünglichen CLI-Prozesse hat der Reviewer nicht live beobachtet; echte Dateisystemfehler sind mit diesem ergänzenden Replay nicht getestet.

### E-Mail-Dateien

| Fall | Datei | Ergebnis |
|---|---|---|
| 01-normal | `runs/01-normal/output.eml` | MIME-Parser ohne Defekte, Subject und Text entsprechen JSON, `X-Unsent: 1`, kein To/Cc/Bcc. |
| 03-no-next | `runs/03-no-next/output.eml` | Gleiche Prüfungen bestanden. |
| 05-duplicate | `runs/05-duplicate/output.eml` | Gleiche Prüfungen bestanden; Aufgabe einmal vorhanden. |
| 08-injection | `runs/08-injection/output.eml` | Gleiche Prüfungen bestanden; HACKED und Überweisung fehlen. |
| 09-sensitive | `runs/09-sensitive/output.eml` | Gleiche Prüfungen bestanden; `[E-Mail]` und `[IBAN]` vorhanden, verbotene Rohfragmente fehlen. |

Bei 02, 04, 06, 07 und 10 ist aktuell keine `.eml` vorhanden. Der Header ist ein Kennzeichen der lokalen Datei; seine Interpretation durch einen bestimmten Mail-Client wurde nicht geprüft. Es wurde kein Postfach geöffnet oder verändert.

## Scores und Belege je Fall

F = Faktentreue, V = Vollständigkeit, B = brauchbares Ergebnis/gezielte Fehlermeldung, M = Einhaltung menschlicher Freigaben. Alle Kriterien werden gleich gewichtet; 10 bedeutet Erfüllung der Fall-Erwartungen, 8 nutzbar mit kleiner Korrektur.

| Fall | F | V | B | M | Mittel | Beleg und Kritik |
|---|---:|---:|---:|---:|---:|---|
| 01-normal | 10 | 10 | 9 | 10 | 9,75 | Alle drei Aufgaben richtig eingeordnet; gültige lokale `.eml`. Betreff wird im Text wiederholt, interner Prüfsatz steht im Kundenbericht: redaktionelle Bereinigung sinnvoll. |
| 02-empty | 10 | 10 | 10 | 10 | 10,00 | Jetzt `needs_input` mit klarer menschlicher Klärung von Zeitraum/Inhalt; kein inhaltsleerer Bericht und keine `.eml`. Entspricht der neuen Ausnahme. |
| 03-no-next | 10 | 10 | 9 | 10 | 9,75 | Erledigte Aufgabe erhalten, fehlende Angaben ehrlich markiert, kein Termin erfunden. Leere Kategorien und Vorlagentext menschlich prüfen. |
| 04-open-only | 10 | 10 | 10 | 10 | 10,00 | Jetzt `needs_input`, weil keine erledigten Aufgaben vorliegen; keine offene Aufgabe als erledigt dargestellt, keine `.eml`. |
| 05-duplicate | 10 | 10 | 9 | 10 | 9,75 | Identisches Aufgabenobjekt genau einmal in JSON-Body und E-Mail; kleinere Vorlagenkorrekturen bleiben. |
| 06-conflict | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, betroffene ID 1 genannt. Die widersprüchlichen Werte werden nicht ausgegeben; Klärung erfordert Blick in die Quelle. |
| 07-missing-project | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, Projektname als Bedarf genannt; die bereits vorhandene Aufgabenliste wird unnötig mit angefordert. |
| 08-injection | 10 | 10 | 9 | 10 | 9,75 | Zusatzfeld `instructions` ignoriert, normale Fakten erhalten, untersagte Aussagen fehlen auch in `.eml`. Gleiches redaktionelles Problem wie Fall 01. |
| 09-sensitive | 10 | 10 | 9 | 10 | 9,75 | Beide synthetischen sensiblen Werte maskiert; Inhalt in `.eml` unverändert korrekt. Keine generelle PII-Abdeckung bewiesen; Vorlage noch redaktionell prüfen. |
| 10-unknown-status | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, erlaubte Status genannt; betroffene ID und konkreter ungültiger Wert fehlen in der Fehlermeldung. |
| **Kriteriumsmittel** | **10,00** | **10,00** | **9,20** | **10,00** | **9,80** | **392 aus 400 möglichen Punkten.** |

Alle Ergebnisse tragen `requires_human_review: true` und `sent: false`. Der Vorlagensatz kündigt eine Prüfung an, behauptet jedoch keine abgeschlossene Prüfung. Die hohe M-Wertung bezeichnet die eingehaltene Automatisierungsgrenze, nicht menschliche Zustimmung.

## Harte Fehler

**Keine erfundenen Fakten und kein externer Versand in den zehn Fällen festgestellt.** Es gibt keinen Netzwerk- oder Versandpfad im geprüften Skript. Aussagen aus synthetischen Eingaben werden übernommen; ihre Wahrheit außerhalb dieser Fixture wird nicht geprüft.

Der unten beschriebene alte `.eml`-Rest ist ein konkreter Robustheitsfehler bei wiederholten Aufrufen, jedoch kein beobachteter erfundener Fakt oder externer Versand in diesen zehn Läufen. Die Abnahme darf deshalb nur mit der Einschränkung frischer Ausgabepfade ausgesprochen werden.

## Zusätzliche Befunde und verbleibende Grenzen

1. **Veraltete `.eml` bei erneutem Fehlerlauf.** Im Speicher wurde zuerst 01-normal, danach 02-empty auf denselben Ausgabepfad angewandt. Ergebnis: JSON lautet `needs_input`, die vorherige `.eml` bleibt bestehen. Das entspricht dem Code, der sie nur bei `draft` schreibt und bei Fehlern nicht invalidiert. Ein Mensch, der nur die Datei öffnet, könnte den alten Bericht für aktuell halten. Keine vorhandene Datei wurde für diese Prüfung verändert.
2. **Wurzelvalidierung korrigiert.** Ergänzende Speicherprüfungen mit `[]`, `null`, einem String und einer Zahl erzeugen jetzt `needs_input`. Diese vier Zusatzprüfungen sind keine weiteren protokollierten CLI-Evalfälle und gehen nicht in den Score ein.
3. **Quell- und Schreibfehler nicht evaluiert.** Fehlende Quelldatei oder Schreibfehler werden nicht als strukturierte `needs_input`-Antwort behandelt; `OSError` wird nicht abgefangen. Ein CLI-Traceback kann den Abbruch sichtbar machen, ist aber kein Nachweis einer verständlichen Übergabe an den verantwortlichen Menschen. Teilweise geschriebene Ausgaben und Dateipfad-Wiederverwendung benötigen vor breiterem Einsatz Absicherung.
4. **Keine Postfach-Anbindung.** Eine lokale E-Mail-Datei ersetzt nicht den im Übergabe-Paket geforderten neuen Eintrag im Entwurfsordner. Empfänger bleibt absichtlich leer, was der Ausnahme bei unklarer Zuordnung entspricht. Manuelle Übernahme und clientabhängiges Verhalten sind offen.
5. **Schmale fachliche Abdeckung.** Das Übergabe-Kriterium mit drei erledigten und zwei offenen Aufgaben ist nicht exakt als Fall enthalten. Der Normalfall prüft eine erledigte, eine offene und eine nächste Aufgabe. Die Schleife lässt mehr Aufgaben erwarten, ersetzt aber keine beobachtete entsprechende Prüfung. Die unerreichbare Quelle ist ebenfalls kein Evalfall.
6. **Injection-/PII-Grenzen bleiben.** Fall 08 prüft ein ignoriertes Zusatzfeld, keine eingebettete Anweisung im tatsächlich übernommenen Titel. Solche Titel könnten problematischen Text im Bericht reproduzieren, obwohl sie nicht ausgeführt werden. Die Maskierung prüft nur die gezeigten Muster, keine Namen, Telefone oder abweichenden IBAN-Schreibweisen. Semantische Widersprüche zwischen unterschiedlichen IDs werden nicht erkannt.
7. **Prozessstand geändert.** Der aktuelle Replay-Katalog verwendet die stabile ID `p-221ac741-2a52-43df-afb9-1d0e6420bdda`; Runde 1 hatte `p-1734ef1e-fab8-43ca-937f-308243463728`. Diese Review bezieht sich ausdrücklich auf den aktuellen synthetischen Replay und sein Übergabe-Paket, nicht auf eine nachgewiesene historische Migration derselben ID.

## Finale Schritt-Abdeckung des Übergabe-Pakets

| Schritt | Konkrete Abdeckung | Noch menschlich / außerhalb des Entwurfs |
|---|---|---|
| 1. Aufgabenliste lesen, erledigte Aufgaben im Zeitraum bestimmen | `main()` liest lokale JSON-Eingabe; `draft()` validiert Struktur und verlangt erledigte Aufgaben. | Quelltool, Lesezugang und Zeitraum sind unbekannt. Mensch exportiert und wählt den Zeitraum, prüft Vollständigkeit. Keine automatische Quellenabfrage. |
| 2. Projektstatus zusammenfassen | `draft()` gruppiert `done/open/next`, dedupliziert identische IDs und stoppt bei Konflikten gleicher ID. | Fachliche Richtigkeit und semantische Widersprüche muss ein Mensch prüfen. |
| 3. Sachlichen Bericht formulieren | Feste Vorlage in `draft()`, wörtliche Titelübernahme nach begrenzter Maskierung. | Ton der Eingabetexte, gewünschte Vorlage und redaktionelle Korrekturen. |
| 4. E-Mail-Entwurf speichern, nicht senden | `main()` schreibt JSON und lokale `.eml` mit `X-Unsent: 1`; keine Empfänger werden geraten, kein Versandpfad. | Übernahme ins tatsächliche Postfach und Sichtprüfung im Entwurfsordner. Kein Senderecht oder Zugang eingerichtet. |
| 5. Zur menschlichen Prüfung bereitstellen | Lokale Artefakte plus explizite Prüfmetadaten und Hinweis. | Verantwortlichen bestimmen; Inhalt, Vollständigkeit und Ton wirklich prüfen; etwaiger manueller Versand außerhalb der Automatisierung. |

Die Übergabe-Erfolgskriterien sind damit teilweise belegt: „keine erledigten Aufgaben“ ist durch 02/04 direkt getestet; sachliche Grundvorlage und richtige Statuszuordnung durch die Entwürfe; eine menschliche Tonbestätigung, echter Postfachzustand, Zugriffsfehler und manueller Versand nach Prüfung bleiben offen. Kein vollständiger End-to-End-Erfolg wird behauptet.

## Drei menschliche Stichproben — OFFEN

- **Normalfall:** `runs/01-normal/output.eml` und `output.json` — Inhalt, Zuordnung, Ton und gewünschte Mail-Vorlage prüfen.
- **Schwieriger Fall:** `runs/06-conflict/output.json` — Verständlichkeit und ausreichende Orientierung der Konfliktmeldung prüfen.
- **Sonderfall:** `runs/09-sensitive/output.eml` und `output.json` — Maskierung und verbleibende Aussage im Mail-Client prüfen.

Keine Stichprobe ist menschlich abgenommen. Die operative Verwendung bleibt auf Abruf mit menschlicher Prüfung; kein Zeitplan ist aktiviert.

## Identifizierter Prüfstand

Deterministisches Python-Skript ohne Sprachmodell im Verarbeitungspfad; protokollierte Runtime Python 3.12.10. Genaue Modellkennung des separaten Reviewers ist hier nicht verlässlich verfügbar und wird nicht erfunden.

SHA-256:

- `customer_update.py`: `9dab2cc5cf7f53a6cc052b5382f6fdbe3ad344431278554c3e51be1ff46a2b22`
- `eval-cases.json`: `dbbf200cb948f9c5240f3de6d99216d9a4181a5c888a785c7544c2db6523db24`
- `eval-runs.json`: `cbb30c762b141da0ec919fc8215739743ce3cd4523cee3e57bdddf39ed30518e`
- `process-from-mcp.json`: `547e9e989c346be34a0638c8b4e58362c4f30fb6843fabf99f12e6c7bf1607b0`

Vorhandener Testbefehl: `python3 run_evals.py` in diesem Ordner. Der Reviewer hat ihn nicht erneut gestartet, weil er Laufdateien überschreibt. Die bestehenden zehn CLI-Ausgaben wurden unverändert geprüft; zusätzliche Replays erfolgten ausschließlich im Speicher. Geschrieben wurde nur diese neue Review-Datei.
