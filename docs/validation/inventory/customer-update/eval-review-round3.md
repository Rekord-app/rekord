# Unabhängige Abschlussprüfung — Runde 3 von höchstens 3

Prüfdatum: 2026-10-15. Separater Codex-Prüfagent; keine gewünschten Scores vorgegeben. Bewertet wurden `rubric.md`, aktuelle `eval-cases.json`, `eval-runs.json`, `customer_update.py`, `run_evals.py`, das unveränderte finale Übergabe-Paket in `process-from-mcp.json` sowie alle gespeicherten Ein-/Ausgaben und E-Mail-Dateien. Maßstab ist der Workspace-Skill `prozess-automatisieren`.

## Abschließendes Ergebnis

**9,80/10; keine harten Fehler in den zehn aktuellen Fällen.** Der lokale Entwurf mit strukturierten Eingaben erfüllt die technische Abnahmeschwelle nach drei Runden. Die beiden gezielt geprüften Regressionen bestehen: Ein Fehlerlauf entfernt den vorherigen lokalen E-Mail-Entwurf, und eine fehlende Quelldatei führt zu `needs_input`. Die Einschränkung aus Runde 2, zwingend einen frischen Ausgabeordner zur Vermeidung alter `.eml` zu benötigen, ist für diese geprüften Fehlerpfade aufgehoben.

Die Abnahme umfasst den lokalen Auf-Abruf-Entwurf mit menschlicher Prüfung. **Keine vollständige Postfachintegration und keine menschliche Abnahme:** `.eml`-Dateien wurden nicht als native Entwürfe in einem echten Postfach angelegt; die drei menschlichen Stichproben sind weiterhin offen. Es ist keine vierte Eval-Runde erforderlich, um die erreichte lokale Schwelle festzustellen.

## Nachweis der zehn tatsächlichen Läufe

Alle zehn gespeicherten CLI-Läufe: Exit-Code 0, leeres stderr, passende Fall-IDs, unveränderte Eingaben gegenüber den Testfällen und passende Einzel-Ausgaben. Erwartete Status, Fakten, untersagte Aussagen und Eindeutigkeit bestehen. Jeder Lauf nennt Python 3.12.10, den aktuellen Skript-Hash und einen UTC-Abschlusszeitpunkt zwischen 2026-10-15 11:51:00.929608 und 11:51:01.003782. Der Runner erlaubt höchstens drei parallele Prozesse.

Der Reviewer reproduzierte zusätzlich `main()` für sämtliche Eingaben mit im Speicher ersetzten Dateioperationen. Alle JSON-Ergebnisse stimmen nach ausschließlicher Normalisierung des lokalen Ausgabedateinamens überein. Alle fünf erzeugten E-Mail-Dateien stimmen bytegenau mit den gespeicherten `.eml` überein. Die ursprünglichen CLI-Prozesse wurden vom Reviewer nicht live beobachtet; die gespeicherten Artefakte, Metadaten und unabhängigen Replays sind die Belege.

Bei 01, 03, 05, 08 und 09 liegen E-Mail-Dateien vor: jeweils ohne Parserdefekte, mit passendem Betreff und Body, `X-Unsent: 1` und ohne To/Cc/Bcc. Bei 02, 04, 06, 07 und 10 ist keine `.eml` vorhanden. Der Marker beweist keinen bestimmten Umgang eines Mail-Clients mit der Datei; dieser wurde nicht geöffnet.

## Scores je Fall

F = Faktentreue, V = Vollständigkeit, B = brauchbarer Entwurf/gezielte Fehlermeldung, M = Einhaltung menschlicher Freigaben. Gleichgewichtung aller vier Kriterien, jeweils 1–10.

| Fall | F | V | B | M | Mittel | Belege und konkrete Kritik |
|---|---:|---:|---:|---:|---:|---|
| 01-normal | 10 | 10 | 9 | 10 | 9,75 | Jetzt exakt drei erledigte und zwei offene Aufgaben plus nächster Schritt. Alle Fakten in der richtigen Kategorie, kein offener Punkt als erledigt. `.eml` korrekt. Betreff im Body und interner Prüfsatz benötigen ggf. redaktionelle Bereinigung. |
| 02-empty | 10 | 10 | 10 | 10 | 10,00 | `needs_input`, klare Aufforderung zur menschlichen Klärung von Zeitraum/Inhalt, keine leere E-Mail. |
| 03-no-next | 10 | 10 | 9 | 10 | 9,75 | Erledigte Aufgabe erhalten, Lücken ausdrücklich markiert; kein Freitag erfunden. Leere Kategorien und Vorlage vor Versand prüfen. |
| 04-open-only | 10 | 10 | 10 | 10 | 10,00 | `needs_input`, keine erledigte Aufgabe erfunden, keine `.eml`; entspricht der Übergabe-Ausnahme. |
| 05-duplicate | 10 | 10 | 9 | 10 | 9,75 | Identische Aufgabe genau einmal enthalten, kleine Vorlagenkorrekturen wie im Normalfall. |
| 06-conflict | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, Konflikt-ID 1 genannt. Die beiden widersprüchlichen Werte fehlen in der Fehlermeldung. |
| 07-missing-project | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, Projektname genannt. Bereits vorhandene Aufgabenliste wird in der Meldung unnötig mit angefordert. |
| 08-injection | 10 | 10 | 9 | 10 | 9,75 | Zusatzfeld ignoriert; HACKED und Überweisung fehlen auch in `.eml`. Redaktionelle Vorlagenkritik bleibt. |
| 09-sensitive | 10 | 10 | 9 | 10 | 9,75 | Synthetische E-Mail und IBAN maskiert; verbotene Rohfragmente fehlen auch in `.eml`. Kleine Vorlagenkorrektur bleibt. |
| 10-unknown-status | 10 | 10 | 9 | 10 | 9,75 | `needs_input`, erlaubte Status genannt. Konkreter falscher Wert und betroffene ID könnten die Meldung verbessern. |
| **Kriteriumsmittel** | **10,00** | **10,00** | **9,20** | **10,00** | **9,80** | **392 von 400 Punkten.** |

Die Faktentreue bezieht sich auf die synthetischen Eingaben. Eine Überprüfung ihrer Wahrheit in einem externen System fand nicht statt. Die M-Wertung bewertet die eingehaltene Grenze: überall `requires_human_review: true`, `sent: false`, keine Behauptung einer bereits erfolgten Prüfung.

## Harte Fehler

**Keine erfundenen Fakten und kein externer Versand in den zehn Ergebnissen oder den ergänzenden Regressionen festgestellt.** Das Skript hat keinen Netzwerk- oder Versandpfad. Keine Produktionsaktion wurde ausgeführt.

## Gezielte Regressionen

Die folgenden Zusatzprüfungen wurden im Speicher direkt gegen das unveränderte `main()` ausgeführt. `Path.read_text`, `write_text`, `write_bytes` und `unlink` wurden durch ein gemeinsames Speicher-Dateisystem ersetzt. Sie zählen nicht als zusätzliche protokollierte CLI-Fälle und nicht zum Score; es wurden dadurch keine echten Dateien geschrieben oder gelöscht.

| Regression | Ablauf | Beobachtetes Ergebnis |
|---|---|---|
| Wiederverwendung nach fachlichem Fehler | 01-normal erzeugt `.eml`, danach 02-empty auf demselben Ausgabepfad. | `.eml` entfernt; JSON `needs_input`, `sent: false`, `requires_human_review: true`; klarer Hinweis auf fehlende erledigte Aufgaben. **Bestanden.** |
| Fehlende Quelldatei nach erfolgreichem Lauf | Zunächst 01-normal, danach löst das Lesen der Quelle einen `FileNotFoundError(2, …)` aus. | Fehler abgefangen; `.eml` entfernt; JSON `needs_input`, `sent: false`, `requires_human_review: true`; Fehlermeldung nennt „No such file or directory“ und den Eingabepfad. **Bestanden.** |

Die fehlende Quelle ist damit auf Ebene des lokalen Dateilesens geprüft. Ein tatsächlicher Ausfall eines noch unbekannten Aufgaben-API-Zugangs ist kein getesteter Integrationsfall. Die Fehlermeldung ist technisch verständlich, aber noch kein ausdrücklich an einen benannten Menschen zugestellter Hinweis.

## Entwicklung über drei Runden

| Runde | Bewertetes Ergebnis | Wesentliche Änderung / verbleibender Befund |
|---|---|---|
| 1 | 9,73/10, keine harten Fehler in damaligen Fällen | Lokaler JSON-Entwurf; leere Berichte möglich, keine `.eml`, keine Versionsmetadaten. |
| 2 | 9,80/10, begrenzte technische Abnahme | Leere Berichte gestoppt, JSON-Wurzel validiert, `.eml` und Metadaten hinzugefügt. Wiederverwendung konnte alte `.eml` zurücklassen. |
| 3 | 9,80/10, lokale technische Abnahme | Alte `.eml` auf geprüften Fehlerpfaden entfernt, Lese-I/O-Fehler abgefangen; Normalfall deckt drei erledigte und zwei offene Aufgaben ab. |

`eval-runs-round1.json` und `eval-runs-round2.json` enthalten jeweils zehn archivierte Läufe mit Exit-Code 0. Gleicher Score in Runde 2 und 3 bedeutet keine fehlende Verbesserung: Die behobenen Regressionen erweitern die Robustheit außerhalb der zehn gleich gewichteten Fallbewertungen. Die unterschiedlichen Runden und Prozessstände werden nicht als identische Testbedingungen ausgegeben.

## Finale Schritt-Abdeckung

| Übergabe-Schritt | Implementierung | Menschliche oder offene Arbeit |
|---|---|---|
| Aufgabenliste lesen und relevanten Zeitraum bestimmen | `main()` liest lokale JSON-Datei, fängt Lese-I/O-Fehler ab; `draft()` validiert die Struktur. | Mensch beschafft die Daten und wählt Zeitraum/Kundenkreis. Aufgaben-Tool und API-Zugang ungeklärt. |
| Projektstatus zusammenfassen | `draft()` gruppiert Status, dedupliziert identische Aufgaben-IDs und blockiert Konflikte derselben ID. | Fachliche Plausibilität, semantische Konflikte zwischen unterschiedlichen IDs und Vollständigkeit der Quelle. |
| Sachlichen Bericht formulieren | Feste Vorlage mit übernommenen Aufgabentiteln und begrenzter Maskierung. | Ton der Quelldaten, gewünschte Vorlage und redaktionelle Korrekturen. |
| E-Mail-Entwurf speichern, nicht senden | `main()` entfernt den bisherigen lokalen E-Mail-Ausgang und schreibt bei Erfolg JSON plus `.eml` mit `X-Unsent: 1`. Keine geratenen Empfänger, kein Versandpfad. | Native Postfachintegration fehlt. Mensch übernimmt und prüft den Entwurf im gewünschten Mail-Client. |
| Zur menschlichen Prüfung bereitstellen | Lokale Artefakte, `requires_human_review` und Prüfhinweis. | Verantwortlicher Prüfer, wirkliche Inhalts-/Tonprüfung sowie möglicher manueller Versand außerhalb des Skripts. |

Vom Übergabe-Paket sind Statuszuordnung mit drei erledigten und zwei offenen Aufgaben, leere Aufgabenlisten, lokaler Leseausfall und das Unterlassen automatischen Versands belegt. Der echte Postfachzustand, menschlich bestätigter Ton und eine tatsächliche Freigabe vor manuellem Versand bleiben offen.

## Verbleibende Grenzen

- **Ausgabe-I/O:** Das neue `except OSError` umfasst das Einlesen, nicht das nachfolgende Löschen oder Schreiben. Berechtigungsfehler, voller Datenträger oder Teil-Schreibfehler können weiterhin zum CLI-Abbruch statt zu einer strukturierten Fehlerantwort führen. Atomare Ausgabe und gleichzeitige Aufrufe mit demselben Ziel sind nicht abgesichert oder getestet. Die Regressionsfreigabe setzt normale Schreib-/Löschrechte voraus.
- **Eingabetext:** Fremdanweisungen im ignorierten Zusatzfeld sind getestet. Instruktionen oder falsche Aussagen innerhalb tatsächlich übernommener Titel können als Text im Bericht erscheinen; sie werden nicht ausgeführt. Kein semantischer Filter oder freie Textinterpretation.
- **Maskierung:** Keine allgemeine PII-Garantie; nur die getesteten E-Mail-/IBAN-Muster. Andere personenbezogene Angaben und abweichende Schreibweisen sind nicht abgedeckt.
- **Betrieb:** Kein Scheduler, kein Deployment, kein Mail-Zugang, keine API-Anbindung und kein benannter Prüfer. Das aktuelle Übergabe-Paket gehört zum synthetischen Replay-Prozess `p-221ac741-2a52-43df-afb9-1d0e6420bdda`.

## Drei menschliche Stichproben — weiterhin OFFEN

- **Normalfall:** `runs/01-normal/output.eml` und `output.json` — drei erledigte und zwei offene Aufgaben, Ton, Vorlage und Darstellung im Mail-Client prüfen.
- **Schwieriger Fall:** `runs/06-conflict/output.json` — prüfen, ob die Konfliktmeldung zum sicheren Auflösen reicht.
- **Sonderfall:** `runs/09-sensitive/output.eml` und `output.json` — Maskierung, Lesbarkeit und Aussage prüfen.

Keine dieser Stichproben wurde menschlich freigegeben. Auf Abruf mit menschlicher Prüfung ist der vorgesehene Betriebsumfang.

## Prüfstand und Reproduktion

Verarbeitungsmodell: deterministisches Python-Skript, kein Sprachmodell im Verarbeitungspfad. Runtime laut Laufprotokoll: Python 3.12.10. Reviewer: separater Codex-Agent; genaue Modellkennung nicht verlässlich verfügbar.

SHA-256:

- `customer_update.py`: `789ea68f01a02d56e1a3217a8e35694bc1ea1d8e27af602dcc9c4f00d86defb2`
- `eval-cases.json`: `d7813c9fa9f3a2b992cc5d4b6fedc3cbd96c28d92084c14b7e2db881db43f2e7`
- `eval-runs.json`: `e84aa31278e56d263100e7d56530476ad473086abee0f46dc257bb604af5fbbd`
- `process-from-mcp.json`: `547e9e989c346be34a0638c8b4e58362c4f30fb6843fabf99f12e6c7bf1607b0`

Der vorhandene Testbefehl ist `python3 run_evals.py` im Ordner dieser Datei. Der Reviewer hat ihn nicht erneut ausgeführt, da er bestehende Artefakte überschreibt. Die zehn vorhandenen CLI-Läufe wurden geprüft, zusätzliche Replays und Regressionen erfolgten im Speicher. Ausschließlich diese neue Review-Datei wurde geschrieben.
