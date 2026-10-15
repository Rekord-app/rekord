# Veröffentlichung

Der Quellstand 1.8.1 bereitet den Launch vor. Die bisherigen veröffentlichten ZIPs sind lokal signiert und nicht als notarisiert nachgewiesen. Erst ein erfolgreich geprüfter Release darf als Developer-ID-signiert und notarisiert bezeichnet werden.

## Voraussetzungen

- macOS SDK 26+ / Xcode 26+, bestehende Tests und öffentliche Exportprüfung bestanden.
- Passender öffentlicher Commit mit exakt demselben exportierten Inhalt; keine privaten Betriebsdateien im Export.
- Gültiges **Developer ID Application**-Zertifikat samt privatem Schlüssel im Schlüsselbund. `Apple Development`, Ad-hoc oder lokale selbst signierte Zertifikate reichen nicht.
- Notarytool-Zugang als Keychain-Profil eingerichtet. Geheimnisse niemals in Git, Terminalprotokolle oder Chat kopieren.
- Share-Server bereits auf `guide-lifecycle-v2`, Backup und Wiederherstellung getestet.

Die Release-Anforderungen folgen [Apples Notarisierungsdokumentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Der lokale Entwicklungsbuild behält seine stabile lokale Signatur. Distribution signiert den MCP-Helper zuerst, dann das App-Bundle mit Hardened Runtime und sicherem Zeitstempel.

## Ablauf

1. Sauberen Commit herstellen und Tests aus [CONTRIBUTING](../CONTRIBUTING.md) ausführen.
2. `scripts/export-public.sh HEAD /tmp/rekord-public-review` erzeugt nur eine neue lokale Exportkopie. Inhalte und lokale Dokumentationslinks prüfen. `scripts/publish-public.sh` veröffentlicht erst nach Setzen des überprüften `EXPECTED_PUBLIC_COMMIT`. Abweichende Community-Änderungen müssen zuvor übernommen werden.
3. Den dadurch erzeugten vollständigen öffentlichen Commit als `PUBLIC_COMMIT` setzen. `REKORD_SIGNING_IDENTITY` enthält den Namen oder SHA-1 des vorhandenen Developer-ID-Zertifikats, `REKORD_NOTARY_PROFILE` nur den Namen des Keychain-Profils.
4. `scripts/release.sh --package /tmp/rekord-release-review` vergleicht beide Quellstände, baut einen sauberen Checkout, notarisiert, stapelt das Ticket, prüft Gatekeeper und erstellt erst danach ZIP und Manifest. Es veröffentlicht nichts.
5. ZIP aus dem endgültigen Artefakt auf einem frischen Mac-Benutzerprofil installieren. Erststart ohne Umgehung von Gatekeeper, Freigaben, Aufnahme/Export, MCP, Teilen/Widerruf und Update prüfen. Reale Meet-/FaceTime- und Inventur-Abnahmen getrennt dokumentieren. 5–10 echte Testnutzer vor breiter Bewerbung einbeziehen.
6. Manifest, ZIP-Hash und Release-Text prüfen. `scripts/release.sh --publish /tmp/rekord-release-review` prüft das Artefakt nochmals und erstellt den GitHub-Release am festgelegten öffentlichen Commit.

Das Manifest nennt privaten und öffentlichen Commit, öffentlichen Git-Tree, Swift-/SDK-Version und SHA-256 der endgültigen ZIP. Änderungen nach dem Stapeln erfordern erneute Signatur-/Notarisierungsprüfung. Keine automatischen Ausnahmen bei fehlenden Zertifikaten oder abgelehnter Notarisierung.

Beim Wechsel von lokaler Signatur zu Developer ID können Bildschirm-, Mikrofon-, Kamera- und Schlüsselbundfreigaben erneut nötig sein. Vor einem Update laufende Aufnahmen abschließen und Rekord beenden. Lokale Aufnahmen nicht löschen. Änderungen am öffentlichen Repository werden nie durch Force-Push überschrieben.
