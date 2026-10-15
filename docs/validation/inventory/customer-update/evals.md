# Kunden-Update-Mail – Eval-Abnahme, 15.10.2026

Quelle: `process-from-mcp.json`, tatsächlich über `get_process` gelesen. Prozess-ID `p-221ac741-2a52-43df-afb9-1d0e6420bdda`. Methode: Claude-Code-Skill mit lokalem Python-Skript; kein Versand, kein Zeitplan.

Drei Runden mit jeweils zehn echten CLI-Läufen, höchstens drei gleichzeitig. Unabhängiger Prüf-Agent: Runde 1 **9,73/10**, Runde 2 **9,80/10**, Runde 3 **9,80/10**. Finale zehn Fälle und fünf `.eml` geprüft, keine harten Fehler. Zwei Zusatzregressionen (alte `.eml` bei `needs_input`, fehlende Quelldatei) im unabhängigen Replay bestanden. Details: `eval-review-round3.md`, `eval-runs.json` mit Skript-Hash, Python-Version und Laufzeitstempel, `runs/` mit Ein-/Ausgaben.

## Abdeckung der fünf Schritte aus dem Übergabe-Paket

| Vorschlag | Umgesetzt |
|---|---|
| Aufgabenliste lesen, Zeitraum festlegen | `main()` liest lokale JSON; Mensch liefert gewählten Zeitraum und strukturierten Export. Nicht erreichbare Quelle → `needs_input`. Externe Verbindung bleibt offen. |
| Projektstatus zusammenfassen | `draft()` prüft IDs, Status, Konflikte und gruppiert erledigt/offen/nächste Schritte. |
| Sachlichen Kundenbericht formulieren | Deterministische Vorlage aus den gelieferten Fakten; keine KI-Halluzinationen. |
| Mail-Entwurf ablegen | `main()` schreibt `.eml` mit X-Unsent sowie JSON; Import ins konkrete Postfach bleibt beim Menschen. |
| Entwurf prüfen | Human-in-the-loop-Markierung immer gesetzt, kein Empfänger/Versand; menschliche Abnahme noch offen. |

Das ergänzende `../n8n-workflow.json` ist nur ein inaktives Integrationsgerüst mit Platzhaltern und Durchreich-Knoten, kein fertig ausführbarer n8n-Workflow. Die tatsächlich getestete Implementierung ist `customer_update.py` plus `SKILL.md`.

## Wartet auf Nikita

Drei Stichproben: `runs/01-normal` (3 erledigte + 2 offene), `runs/06-conflict`, `runs/09-sensitive`. Erst nach menschlicher Prüfung für eigene Daten verwenden. Aufgabenquelle, Zeitraum und Postfach auswählen, falls direkte Integration gewünscht ist. Auf Abruf ist der dokumentierte Standard; nichts automatisch scharfgeschaltet.
