# Keyboard Manager

Keyboard Manager ist eine native macOS-App zum Erfassen, Verwalten und Sichern mechanischer Tastatur-Sammlungen. Sie unterstützt Boards, Keycap-Sets, Artisans und Switch-Sets, lokale Fotos, Galerie und Detailansicht, PDF-/XLSX-Berichte sowie eine nicht-destruktive Übernahme bestehender Keyboard-Manager-V1-Daten.

Die frühere Electron-App dient ausschließlich als unveränderliche Migrationsreferenz. Diese App verwendet einen eigenen Quellcode und einen eigenen Nutzerdatenbereich.

## Lokal bauen

```bash
xcodebuild -project KeyboardManager.xcodeproj -scheme KeyboardManager -configuration Debug test
./script/build_and_run.sh --build
```

Der lokale Debug-Build liegt danach unter `dist/Keyboard Manager.app`.

Für Build und Start:

```bash
./script/build_and_run.sh
```

## Datenschutz

Sammlung und Fotos bleiben lokal. Eine externe Bildadresse wird nur nach sichtbarer Bestätigung und ausschließlich per HTTPS einmalig geladen. Details: [PRIVACY.md](PRIVACY.md).

## Release

Der auslieferbare Build ist ein Developer-ID-signiertes und von Apple notarisiertes universelles DMG. Anleitung, Voraussetzungen und GitHub-CI-Konfiguration: [RELEASE.md](RELEASE.md).

## Dokumentation

- `PROJECT_SUMMARY.md`: V1-Inventur, Zielarchitektur und Datenmodell
- `FEATURE_PARITY.md`: vollständige Funktions- und Umsetzungs-Matrix
- `MIGRATION.md`: nicht destruktive V1→V2-Migrationsstrategie
- `RELEASE.md`: Release- und Notarisierungsprozess

## Lizenz

Dieses Projekt ist unter der [MIT-Lizenz](LICENSE) verfügbar. Hinweise zu ZIPFoundation: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
