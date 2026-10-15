# Unabhängige Eval-Prüfung: Kunden-Update

Prüfdatum: 2026-10-15. Separater Prüf-Subagent; keine gewünschten Scores vorgegeben. Grundlage: `rubric.md`, `eval-cases.json`, `eval-runs.json`, `process-from-mcp.json`, `customer_update.py`, ergänzend `run_evals.py` und die zehn gespeicherten Ein-/Ausgaben in `runs/`. Bewertungsmaßstab: Workspace-Skill `prozess-automatisieren`.

## Ergebnis und Geltungsbereich

**9,73/10 insgesamt; keine harten Fehler in den zehn vorliegenden Fällen.** Die Schwelle von 8/10 ist für den lokalen Entwurf mit strukturierten Eingaben erreicht. Das ist eine technische Eval-Bewertung, keine menschliche Abnahme und keine Bestätigung eines produktiven Mail-Workflows.

Alle zehn gespeicherten Läufe haben Exit-Code 0 und leeres stderr. Ihre Eingaben stimmen mit den Testfällen überein, ihre Ausgaben mit den Einzeldateien. Ein unabhängiger Replay der unveränderten `draft`-Funktion im Speicher reproduziert alle zehn Ergebnisse einschließlich der Fehlerantworten. Erwarteter Status, erwartete Fakten, untersagte Aussagen und die geforderte Eindeutigkeit bestehen in allen Fällen. Es wurden keine bestehenden Dateien überschrieben, keine produktiven Systeme angesprochen und keine Nachrichten versendet.

Die ursprünglichen zehn CLI-Läufe sind durch gespeicherte Ein-/Ausgaben und Runner nachvollziehbar; ihre damalige Ausführung wurde vom Reviewer nicht live beobachtet. Der ergänzende Replay prüft die Funktion, nicht erneut den gesamten CLI-Dateischreibpfad. Der Runner begrenzt gleichzeitig laufende Prozesse auf drei.

## Scores je Fall

F = Faktentreue, V = Vollständigkeit, B = brauchbarer Entwurf bzw. gezielte Fehlermeldung, M = Einhaltung menschlicher Freigaben. Alle Kriterien sind gleich gewichtet. Vollständigkeit beurteilt die ausdrücklich vorhandenen bzw. erwarteten Informationen, nicht die Erfindung fehlender Angaben.

| Fall | F | V | B | M | Mittel | Bewertungsbeleg und konkrete Kritik |
|---|---:|---:|---:|---:|---:|---|
| 01-normal | 10 | 10 | 9 | 10 | 9,75 | Alle drei Aufgaben stehen in der richtigen Kategorie; keine verbotenen Zusagen. Betreff wird zusätzlich im Body ausgegeben, der interne Prüfsatz steht im Kundentext: kleine redaktionelle Bereinigung vor Übernahme in Mail. |
| 02-empty | 10 | 10 | 8 | 10 | 9,50 | Dreimal ausdrücklich „Keine Angaben in der Aufgabenliste.“; keine erfundenen Aufgaben. Der erwartete Status `draft` stimmt. Als Kundenbericht ohne Inhalt wenig nützlich; ein Mensch muss zunächst Informationen beschaffen. |
| 03-no-next | 10 | 10 | 9 | 10 | 9,75 | Erledigte Aufgabe vollständig, fehlende offene Aufgaben und nächste Schritte ausdrücklich kenntlich gemacht; kein Freitag erfunden. Fehlende nächste Schritte müssen für einen gehaltvollen Bericht ggf. ergänzt werden. |
| 04-open-only | 10 | 10 | 9 | 10 | 9,75 | Freigabe korrekt unter „Offen“, keine Abschlussbehauptung. Leere Kategorien bleiben sichtbar; vor Versand redaktionell prüfen. |
| 05-duplicate | 10 | 10 | 9 | 10 | 9,75 | Identische Aufgabe erscheint genau einmal. Keine Information des Falls verloren. Dieselben kleinen Vorlagenkorrekturen wie im Normalfall. |
| 06-conflict | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, keine Entwurfsausgabe, Fehler nennt Aufgabe 1. Gezielt genug zum Auffinden; die widersprüchlichen Werte `done` und `open` werden nicht genannt. |
| 07-missing-project | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, Projektname wird als benötigte Information genannt. Fehlermeldung fordert zusätzlich die bereits vorhandene strukturierte Aufgabenliste und ist damit etwas unpräzise. |
| 08-injection | 10 | 10 | 9 | 10 | 9,75 | Separates `instructions`-Feld wird ignoriert; weder HACKED noch Überweisung erscheinen. Inhalt identisch zu 01-normal, daher dieselbe Vorlagenkritik. Kein Nachweis für Fremdanweisungen innerhalb eines Aufgaben-Titels. |
| 09-sensitive | 10 | 10 | 9 | 10 | 9,75 | Synthetische E-Mail und IBAN durch `[E-Mail]` bzw. `[IBAN]` ersetzt; verbotene Rohfragmente fehlen. Die übrige Aussage bleibt erhalten. Vorlagenkorrektur nötig; keine umfassende PII-Garantie daraus ableiten. |
| 10-unknown-status | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, zulässige Status `done/open/next` genannt; kein Entwurf. Fehlermeldung nennt weder betroffene ID noch den ungültigen Wert `maybe`. |
| **Kriteriumsmittel** | **10,00** | **10,00** | **8,90** | **10,00** | **9,73** | **389 Punkte aus 40 Einzelwertungen; ungerundet 9,725.** |

Die Freigabewertung betrifft die Grenze des Entwurfs: Alle Ergebnisse setzen `requires_human_review: true` und `sent: false`. Der Satz „Dieser Entwurf wird vor dem Versand persönlich geprüft“ kündigt eine Prüfung an; er behauptet keine bereits erfolgte Prüfung. Eine tatsächliche Prüfung lässt sich daraus nicht ableiten.

## Harte Fehler

**Keine in den zehn geprüften Ergebnissen.** Kein zusätzlich erfundener Projektfakt und kein externer Versand festgestellt. Der Code besitzt keinen Versand- oder Netzwerkpfad. Dass Eingabeaussagen übernommen werden, belegt deren Übereinstimmung mit den Testdaten, nicht ihre Wahrheit außerhalb der synthetischen Fixture.

## Konkrete Lücken und Produktionsgrenzen

1. **Kein nativer Mail-Entwurf.** `main()` schreibt JSON mit Betreff und Body in eine lokale Datei. Es gibt weder Mail-Anbindung noch Empfänger. Das Prozesskriterium „E-Mail liegt als Entwurf vor“ ist damit nur als lokaler Textentwurf vorbereitet; ein tatsächlicher Entwurf in Mail und die persönliche Versandprüfung sind außerhalb der bewerteten Automatisierung.
2. **Unvollständige Lauf-Provenienz.** `eval-runs.json` speichert ID, Exit-Code, Ausgabe und stderr, jedoch keine Skriptversion, Python-Version, Laufzeit oder Zeitstempel. Eingaben liegen separat vor. Die vom Skill verlangte gespeicherte Version ist in diesem Laufprotokoll nicht enthalten. Der unten dokumentierte aktuelle Hash bindet diese Review an den gelesenen Stand, beweist aber nicht rückwirkend den Stand beim ursprünglichen Lauf.
3. **Schemafehler nicht vollständig abgefangen.** Bei einem gültigen JSON-Wurzelwert wie `[]` oder `null` ruft `draft()` `.get()` auf einem Nicht-Objekt auf. Das ergibt einen `AttributeError`, den `main()` nicht abfängt. Auch Datei-I/O-Fehler erhalten keine gezielte `needs_input`-Antwort. Diese statisch erkennbaren Fälle sind nicht Teil der zehn Läufe; die allgemeine Aussage „Fehlerfälle liefern needs_input“ wäre zu weitgehend.
4. **Fremdanweisungen nur eingeschränkt getestet.** Fall 08 legt die Anweisung in ein ohnehin nicht gelesenes Zusatzfeld. Aufgaben-Titel werden als Text übernommen, nicht semantisch geprüft. Eine Anweisung oder falsche Behauptung in einem Titel könnte im Entwurf auftauchen, obwohl sie nicht ausgeführt wird. Kein LLM, kein `eval` und kein externer Toolaufruf sind vorhanden; die Sicherheit gegen Ausführung ist daher stärker als die geprüfte redaktionelle Reinheit.
5. **Maskierung mit begrenzter Reichweite.** Fall 09 bestätigt genau eine E-Mail- und IBAN-Form. Namen, Telefonnummern, abweichende Schreibweisen sowie falsch positive IBAN-Muster sind nicht evaluiert. Die Regex ist kein allgemeiner Datenschutzfilter. Mehrzeilige Projektnamen werden außerdem unverändert in Betreff und Body übernommen.
6. **Dubletten und Widersprüche anhand der ID.** Nur vollständig gleiche Aufgabenobjekte mit gleicher ID werden zusammengeführt. Unterschiede in Zusatzfeldern können einen Konflikt erzeugen; semantisch widersprüchliche Aufgaben mit verschiedenen IDs werden nicht erkannt. Keine freie Textinterpretation oder automatische Extraktion aus den Rekord-Beispielen.
7. **Offene Prozessfragen bleiben offen.** Aufgaben-Tool, Update-Rhythmus, Kundenkreis, verbindliche Vorlage und verantwortlicher Prüfer sind laut MCP-Prozess noch ungeklärt. Die synthetischen Fälle testen keine Datenbeschaffung, Aktualität, Terminauflösung von „Freitag“, große Listen oder fachlich verschiedene Kundenberichte. Eine Produktionsfreigabe wäre daraus nicht begründbar.

## Schritt-Abdeckung

| Prozessschritt | Umsetzung oder notwendige menschliche Arbeit |
|---|---|
| Projektstatus aus Aufgabenliste zusammenfassen | `draft()`: validiert strukturierte Aufgaben, gruppiert Status, behandelt identische IDs; Beschaffung und fachliche Prüfung der Quelldaten bleiben menschlich. |
| Sachlichen Kundenbericht formulieren | Feste Vorlage in `draft()` mit wörtlicher Übernahme der Titel; keine freie Zusammenfassung. Ton der Vorlage sachlich, Eingabetexte müssen geprüft werden. |
| Als Entwurf speichern, nicht senden | `main()` speichert lokales JSON. Übernahme als tatsächlicher Mail-Entwurf ist ein gesonderter manueller Schritt. |
| Mensch prüft vor Versand | Metadaten und Hinweis fordern Prüfung; tatsächliche Durchführung und Versand sind bewusst nicht implementiert und nicht belegt. |

## Menschliche Stichprobe — weiterhin offen

- **Normalfall: `runs/01-normal/output.json` — OFFEN.** Mensch prüft sachlichen Ton, richtige Zuordnung und die gewünschte finale Mail-Vorlage.
- **Schwieriger Fall: `runs/06-conflict/output.json` — OFFEN.** Mensch beurteilt, ob die Fehlernachricht den Widerspruch ausreichend gezielt auflösen lässt.
- **Sonderfall: `runs/09-sensitive/output.json` — OFFEN.** Mensch prüft Maskierung, Lesbarkeit und ob die verbleibende Aussage für einen Kundenbericht geeignet ist.

Keine dieser Stichproben wurde als menschlich geprüft oder freigegeben markiert.

## Identifizierter Prüfstand

Ausführung des Entwurfs: deterministisches Python-Skript, kein Sprachmodell im Verarbeitungspfad. Reviewer: separater Codex-Prüfagent; genaue Modellkennung in diesem Review nicht verlässlich verfügbar und deshalb nicht erfunden.

SHA-256 der gelesenen Dateien:

- `customer_update.py`: `dbe63efe04caccb6f08726880ba5bb3f81102cfb07e0f2f7595d4a6f7fba82b4`
- `eval-cases.json`: `f962ba5c0fac7e610c01261812da56edfe3fef1c6ebaecc6080feda0edbc4208`
- `eval-runs.json`: `a4a867c47547062213c0533527699bd6ea09ee83ce0fb2c01e48bc09a767cfa8`
- `process-from-mcp.json`: `fbcf12649c89fc4083755edff09885ddc687af2a2cec50c8f52233461a38433c`

Der vorhandene Testbefehl lautet `python3 run_evals.py` im Ordner dieser Review. Er schreibt die bestehenden Laufartefakte neu; der Reviewer hat ihn deshalb nicht ausgeführt, sondern die gespeicherten Resultate unverändert geprüft und die Funktion im Speicher reproduziert.
