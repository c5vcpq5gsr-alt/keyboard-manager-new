# Keyboard Manager – Release-Runbook

Dieses Dokument beschreibt ausschließlich die direkte Verteilung außerhalb des Mac App Store. Ein Debug-Bundle aus `script/build_and_run.sh` ist **nicht** auslieferbar.

## Release-Vertrag

- Produktname: `Keyboard Manager`
- Bundle-ID: `de.r3d42.KeyboardManagerV2` (dauerhaft, unabhängig vom sichtbaren Namen)
- Mindestversion: macOS 14
- Artefakt: ein universelles (`arm64` und `x86_64`) Developer-ID-signiertes und notarisiertes DMG
- Zugangsdaten: ausschließlich im Schlüsselbund oder in GitHub Secrets, nie in Dateien, Git-Historie oder Terminalausgaben

## Einmalige lokale Apple-Einrichtung

Die vorhandene Developer-ID-Identität des V1-Projekts darf auch V2 signieren. Für die Notarisierung verwendet V2 das eigene Schlüsselbundprofil `keyboardmanager-new-notary`. Dadurch kann es unabhängig widerrufen werden.

1. Mit aktivierter Zwei-Faktor-Authentifizierung bei [account.apple.com](https://account.apple.com) unter **Anmeldung und Sicherheit → App-spezifische Passwörter** ein neues Passwort mit der Bezeichnung `Keyboard Manager V2 Notarization` erzeugen. Apples Anleitung: [App-spezifische Passwörter](https://support.apple.com/en-gb/102654).
2. Die vorhandene Signaturidentität prüfen:

   ```bash
   security find-identity -v -p codesigning
   ```

3. Das neue Passwort nur lokal in ein separates `notarytool`-Profil speichern. `APPLE_ID` durch die eigene Apple-ID ersetzen; beim Passwort den gerade erzeugten Wert einsetzen. Der Wert gehört weder in Git noch in einen Screenshot.

   ```bash
   xcrun notarytool store-credentials "keyboardmanager-new-notary" \
     --apple-id "APPLE_ID" \
     --team-id "G6JH37W285" \
     --password "APP_SPECIFIC_PASSWORD"
   ```

4. Das Profil ohne Geheimnis-Ausgabe prüfen:

   ```bash
   xcrun notarytool history --keychain-profile "keyboardmanager-new-notary"
   ```

Apple beschreibt die Anforderungen für Developer ID und Notarisierung unter [Developer ID](https://developer.apple.com/developer-id/) und [Notarisierung vor der Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution?changes=_5).

## Lokales Release erzeugen

Nach Abschluss der Produktabnahme und mit einer gesetzten Releaseversion:

```bash
DEVELOPMENT_TEAM="G6JH37W285" \
SIGNING_IDENTITY="Developer ID Application: YOUR_NAME (G6JH37W285)" \
NOTARY_PROFILE="keyboardmanager-new-notary" \
./script/release.sh
```

Das Skript archiviert beide Architekturen, prüft die App-Signatur, erzeugt das DMG, signiert und notarisiert es, stapelt das Ticket, prüft DMG und enthaltene App und schreibt eine SHA-256-Datei nach `dist/release/`.

## GitHub-Repository und CI

Vor dem ersten externen Push muss Sichtbarkeit und Eigentümer feststehen. Der folgende Befehl erzeugt ein **öffentliches** Repository; bei einem privaten Projekt `--public` durch `--private` ersetzen:

```bash
gh auth status
gh repo create c5vcpq5gsr-alt/keyboard-manager-new --public --source=. --remote=origin --push
```

Anschließend `main` gegen Force-Pushes und Löschen schützen und die in `.github/workflows/release.yml` referenzierten Secrets hinterlegen:

- `APPLE_DEVELOPMENT_TEAM`
- `MACOS_SIGNING_IDENTITY`
- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_P8_BASE64`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER`

Die CI verwendet bewusst einen App-Store-Connect-API-Key, nicht das lokale App-Passwort. Ein Release wird nur aus einem `v*`-Tag oder über den manuellen Workflow erzeugt.
Solange eines dieser Secrets fehlt, beendet der Workflow nach der Credential-Prüfung erfolgreich und überspringt die CI-Notarisierung. Ein lokal erzeugtes, vollständig geprüftes DMG kann weiterhin manuell veröffentlicht werden.

Nach jeder Veröffentlichung muss das hochgeladene DMG frisch heruntergeladen, mit der lokalen SHA-256 verglichen und erneut mit `script/verify_release.sh ... --require-notarization` geprüft werden.
