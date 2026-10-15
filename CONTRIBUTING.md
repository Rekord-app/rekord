# Mitwirken

Rekord ist derzeit unter FSL-1.1-ALv2 veröffentlicht; die Konkurrenzbeschränkung steht in [LICENSE.md](LICENSE.md). Bitte diese Bedingungen vor einer Weiterverwendung prüfen.

Für einen Beitrag: Issue für das konkrete Problem anlegen, Branch erstellen und einen kleinen Pull Request mit Verhalten vorher/nachher und durchgeführten Prüfungen schicken. Bestehende Nutzerdateien, Freigaben und Aufnahmen schützen. Keine Zugangsdaten, echten Meeting-Inhalte oder private Screenshots in Tests/Issues hochladen.

Build: Mac mit Apple-Chip, Xcode 26+ / macOS SDK 26+. Laufzeitbasis macOS 14; Meetings ab 14.2, lokale Spracherkennung ab 26. Der Server benötigt Node 22+.

```sh
scripts/check-release.sh --toolchain
swift build
scripts/test.sh
scripts/test.sh --integration
scripts/test.sh --mcp
npm test --prefix share-service
scripts/test-public-export.sh
```

Der Swift-Testläufer ist ein ausführbares Target; `swift test` ersetzt ihn nicht. Medienprüfungen verwenden synthetische Daten und brauchen keine Live-Aufnahme. Manuelle Mikrofon-/Bildschirmtests vorher bewusst vorbereiten. CI prüft macOS 26 sowie Node 22 und 24.

Sicherheitslücken bitte [privat melden](SECURITY.md). Veröffentlichung und Signierung: [Release-Ablauf](docs/RELEASE.md).
