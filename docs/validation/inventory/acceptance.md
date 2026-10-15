# Arbeits-Inventur – Abnahme 15.10.2026

Version 1.8.0 (10). Implementiert in einem isolierten Worktree; paralleler Stand `84569db` per Cherry-Pick als Basis erhalten. Keine echte Kundenaufnahme, keine Aufnahme von Nikitas Fenstern, keine Screenshots an eine API. Die laufende App blieb während aller Tests unangetastet.

## Prüfmatrix

| Prüfung | Ergebnis / Beleg |
|---|---|
| Core einschließlich unveränderter Guide-/Meeting-Tests | 17 PASS-Ausgaben; Inventur mit 35 gezielten Assertions. `scripts/test.sh` |
| MCP | 6 gültige Inventur-Aufrufe, 14 fehlerhafte Eingaben, Bildpfade nur per Opt-in; bestehende Schutz-/Export-Regressionsprüfungen grün. `scripts/test.sh --mcp` |
| Release | `swift build -c release`, ohne Warnungen; Core-Audio-Pointer und Queue-/Callback-Sendability korrigiert. |
| Synthetischer Arbeitstag | 360 Minuten, 410 Proben, 17 Vorschnitt-Blöcke; **6/6 Prozesse**, alle Häufigkeiten exakt (2/2/4/3/3/2), keine ausgeschlossenen Blöcke/YouTube-Rauschen. [Protokoll](replay.txt) |
| Sprache | Zwei mit synthetischer Stimme erzeugte Antworten lokal transkribiert, Blöcken zugeordnet und in der zweiten Textauswertung verwendet. Keine echte Mikrofonaufnahme. |
| Daten/API | Keine Fixture-E-Mail/IBAN/Ausschlussmarker in gespeicherten Replay-Dateien oder Requests. Nur Text. Beobachtete API-Verbindung `160.79.104.10:443`, gegen `api.anthropic.com` aufgelöst. |
| Schema/Kennzahlen | `rekord.processes`, Version 1; Markdown nach Euro absteigend. Minuten/Häufigkeiten aus lokalen Blöcken, Monatswert = Stunden/Woche × 52/12 × Stundensatz. Kein Versprechen tatsächlicher Ersparnis. |
| Übergabe | Kunden-Update-Paket über echten MCP-Aufruf gelesen; fünf vorgeschlagene Schritte im lokalen Python-Entwurf/der menschlichen Prüfung abgebildet. [Eval-Abnahme](customer-update/evals.md) |
| Eval-Skill | Drei Runden à 10 tatsächliche CLI-Läufe, max. drei gleichzeitig. Unabhängiger Prüfer: 9,73 → 9,80 → **9,80/10**, kein harter Fehler. Zwei Zusatzregressionen bestanden. Wiederverwendbarer Entwurfs-Skill festgeschrieben. |
| Team | Explizite Freigabe, bearbeitbare Texte, separater Export-Datentyp. Core-Prüfung: nur freigegebene Prozesse, keine Block-IDs, Bilder, Proben oder wörtlichen Antworten. Eigene Einwilligung und Pflicht-Menüleiste implementiert. |
| Aufbewahrung | Test alter Tagesordner: Bilder >7 Tage/Rohproben >30 Tage geplant, Blöcke bleiben. Inventur separat in Speicherübersicht; Studio/Loom-Aufräumen greift nicht hinein. |
| Oberfläche | [Tagesansicht](inventory-ui.png) und [Prozess-Liste](inventory-processes-ui.png) aus eigenen Views/Fake-Daten gerendert und visuell geprüft; keine Bildschirmaufnahme. |
| Kontrollierter Live-Test | **Wartet auf Nikita**, AX=false; Diagnose beendet vor jeder Aufnahme. [Protokoll](live-check.txt), OS #211 und #213. |

## Gemessene Last

Replay (beschleunigt): **106,4 Sekunden**, **16.807 Input + 11.460 Output = 28.267 Tokens**, **32.598 Request-Bytes**; 262.144 lokal belegte Bytes. Der Replay prüft die Text-/Prozesskette, keine reale Fensterbildrate.

Separater 10-Minuten-Test: **600,3 s**, 120 Takte à 5 s, 20 OCR-Durchläufe plus geschwärzte JPEGs aus einem generierten Bild; keine Bildschirmaufnahme, kein Netz. `ps` alle fünf Sekunden: **2,70 CPU-Sekunden**, im Mittel **0,45 % eines CPU-Kerns**, höchster gemessener RSS **77,7 MiB**, **593.920 belegte Bytes** inklusive Messdateien (linear ungefähr 3,56 MB/Stunde für diese Fixture). [Rohmessung](benchmark-cpu.json), [Zusammenfassung](benchmark-summary.json). Das ist keine Messung des echten ScreenCaptureKit-/AX-Betriebs. Reale CPU-/Energielast, Kontextwechsel und Bildgrößen bleiben Teil des Live-Tests.

## Wartet auf Nikita

- **OS #211:** Bedienungshilfen für Rekord erlauben. Danach bei entsperrtem Bildschirm kontrollierten 10-Minuten-Test mit Fake-Fenster wiederholen, Leerlauf/Ausschluss und private Fenster je verwendetem Browser prüfen. CPU dabei messen. Mikrofon-Test mit geöffnetem Deckel/externer Quelle. Panel-Verhalten bei echter Aufnahme/Meeting ebenfalls abnehmen; Sperren und sofortiges Abbrechen sind implementiert.
- **OS #213:** Mindestens vier Stunden echte Nutzung, anschließend zehn Minuten Prozessbewertung; Ziel mindestens 70 % „stimmt so“. Vorher Ausschlüsse prüfen.
- Drei menschliche Eval-Stichproben (01-normal, 06-conflict, 09-sensitive); tatsächliche Aufgabenquelle/Zeitraum/Postfach für eine direkte Integration auswählen. Der lokale `.eml`-Entwurf ist technisch abgenommen, native Postfachintegration bleibt unverbunden. Kein automatischer Versand/Zeitplan.

## Wiederholen

Aus dem Repo `REKORD_APP_DIR=/private/tmp/rekord-dev scripts/build-app.sh debug`. Dev-Bundle per `open -n` mit `--inventory-replay <neuer Ordner> --exit-after-diagnostics` starten, eigenen Schlüssel ausschließlich per `open --env REKORD_CLAUDE_KEY=…` übergeben. `REKORD_INVENTORY_ROOT` auf einen isolierten Fixture-Ordner setzen. `--inventory-ui <Replay-Ordner>` rendert die Views, `--inventory-check <neuer Ordner>` prüft Rechte vor dem kontrollierten Live-Test. Anschließend Dev-Bundle über `lsregister -u` abmelden und löschen. Nie die laufende App für einen Test beenden.

Der Share-Server blieb unverändert. Das ergänzende n8n-JSON ist ein inaktives Gerüst; die Eval-Ergebnisse beziehen sich ausdrücklich auf den tatsächlich ausgeführten lokalen Python-Skill.

Installation: `scripts/install.sh` erst nach Abschluss der Tests, zuvor keine offene Mediendatei im Rekord-Prozess; Dev-Bundle abgemeldet/entfernt. Version 1.8.0 (10) in `~/Applications/Rekord.app` installiert und geöffnet.
