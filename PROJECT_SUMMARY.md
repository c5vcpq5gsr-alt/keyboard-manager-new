# Keyboard Manager V2 – Projektübersicht

Stand: 26. Juli 2026 · Fachliche Restparität und vollständige UI-Abnahme abgeschlossen

## Ziel

Keyboard Manager V2 ist die native macOS-Neuentwicklung des bestehenden Keyboard Managers. Die frühere Electron-App dient ausschließlich als unveränderliche Referenz und als Datenquelle für die Migration. V2 schreibt weder in deren Repository noch in deren Nutzerdaten.

Phase 0 liefert:

- eine vollständige V1-Inventur und eine nachvollziehbare Paritätsmatrix,
- die Zielarchitektur und das normalisierte Datenmodell,
- eine sichere, wiederholbare Migrationsstrategie,
- ein natives SwiftUI-/Xcode-Grundgerüst mit Unit-Tests,
- einen lokal baubaren und startbaren Debug-App-Bundle.

Noch nicht Teil von Phase 0 sind produktive Datenspeicherung, echte V1-Übernahme, Fotoverarbeitung, Berichte, Backups, Updateprüfung, Signierung, Notarisierung, GitHub-Publikation oder Release.

Phase 1A ergänzt einen strikt nur lesenden Import-Prüflauf für V1-ZIP-Backups mit Schema 6:

- nativer Dateiauswahldialog und sichtbare Prüfzustände,
- ZIP-Grenzen, Pfadsicherheit, CRC-Prüfsummen und Manifestvalidierung,
- vollständige Transformation in einen flüchtigen V2-`InventorySnapshot`,
- Referenz-, Mengen-, URL-, MIME- und Bilddekodierungsprüfung,
- Dry-Run-Bericht mit Bestandszahlen, Warnungen und blockierenden Fehlern,
- synthetische Sicherheitsfixtures und Integrationstest gegen den privaten V1.3.2-Export.

Phase 1A schreibt weder V1- noch V2-Inventardaten.

Phase 1B ergänzt:

- ein produktives SQLite-Repository mit transaktionalem Snapshot, `WAL`, `synchronous=FULL` und Integritätsprüfung,
- einen expliziten Bestätigungsdialog vor jeder schreibenden Aktion,
- eine lokale Kopie der gewählten Quelle unter einem eindeutigen Staging-Verzeichnis,
- erneute SHA-256-, Manifest-, Beziehungs-, CRC- und Bildprüfung der Staging-Kopie,
- verlustfreie Bereitstellung aller Fotos mit anhand der Bilddaten normalisierten Endungen,
- Aktivierung als geschlossener `Current`-Bestand aus SQLite, Fotos und Abschlussbericht,
- automatisches Backup eines vorhandenen V2-Bestands und Rollback bei Aktivierungsfehlern.

V1 bleibt auch in Phase 1B unverändert. V2 schreibt ausschließlich in seinen eigenen Application-Support-Bereich.

## Verbindliche Produktprinzipien

1. **Local first:** Sammlungsdaten und Fotos bleiben lokal. Netzwerkzugriffe sind nur für explizite externe Links und eine spätere Updateprüfung vorgesehen.
2. **Nicht destruktive Migration:** V1-Daten werden ausschließlich gelesen. Vor einer Umschaltung wird in einen neuen V2-Datenbereich kopiert, validiert und protokolliert.
3. **Native macOS-Interaktion:** SwiftUI-Szenen, System-Sidebar, Menüs, Tastaturkürzel, native Dialoge, Undo/Redo und zugängliche Fokusführung.
4. **Explizite Zustände:** Laden, Speichern, Importieren, Validieren, Erfolg und Fehler müssen sichtbar sein.
5. **Trennbare Schichten:** UI, App-Zustand, Domänenmodell, Persistenz, Migration, Fotoverarbeitung und Export bleiben unabhängig testbar.
6. **Parität vor Erweiterung:** V1-Funktionen werden in `FEATURE_PARITY.md` einzeln verfolgt. Neue V2-Funktionen dürfen die Datenübernahme nicht gefährden.

## Inventur der Referenz-App V1

### Technischer Aufbau

- Electron 42 mit einem Browserfenster; Hauptoberfläche in einer ca. 6.700 Zeilen großen `index.html`.
- Main Process in `main.js`, abgesicherte Preload-Bridge in `preload.js` (`contextIsolation`, Sandbox, kein Node-Zugriff im Renderer).
- Persistenz in `better-sqlite3`: JSON-Datensätze für vier Inventartypen, separate Foto-Metadaten und ein verwalteter Fotoordner.
- Bestandsberichte als PDF über ein verstecktes Browserfenster und als XLSX über ExcelJS.
- ZIP-Backups über `adm-zip`; Manifest-Schema aktuell Version 6.
- GitHub-basierte Updateprüfung mit 24-Stunden-Cache und erlaubten Release-URLs.
- Deutsch/Englisch-Umschaltung, helles/dunkles Theme und ein nativer Electron-Kontextmenüpfad.

### Oberflächen und Arbeitsabläufe

- Drei Hauptansichten: **Erfassen**, **Übersicht**, **Galerie**.
- Vier Inventartypen: **Keyboards**, **Keycap-Sets**, **Artisans**, **Switch-Sets**.
- Erfassen/Bearbeiten mit Kurzvorschau, dynamisch ergänzbaren Auswahllisten, Fotos, Hauptfoto, sichtbarer Aktion „Verwerfen“ und Warnung bei ungespeicherten Änderungen; missverständliche doppelte Rückgängig-/Speichern-Symbole werden nicht zusätzlich in der Toolbar gezeigt.
- Übersicht mit Kennzahlen, Suche, typabhängigen Filtern, Sortierung, Tabellen, Bearbeiten/Löschen und Switch-Detailaktion.
- Galerie für Boards, Keycaps und Artisans mit Karten und Hauptbildern; Switches besitzen in V1 keine eigene Galerie.
- Spotlight-Dialog für alle vier Typen, Vor/Zurück-Navigation, Thumbnail-Leiste und Foto-Großansicht; Escape und Pfeiltasten werden unterstützt.
- Kopfaktionen für neues Board, ZIP-Backup, Import, Sprache und Theme.
- Bestands-Export aus der Übersicht: PDF oder XLSX, kompletter Bestand oder aktueller Bereich, optional aktuelle Filter; PDF kann bis zu 200 lokale Hauptbilder einbetten.

### V1-Datenhaltung

V1 legt unter dem Electron-`userData`-Verzeichnis ab:

- `keyboard-manager.sqlite`
- `keyboard-manager.sqlite-wal` und `keyboard-manager.sqlite-shm`, falls die App aktiv oder nicht sauber geschlossen ist
- `photos/` mit Dateien `<photo-id>.<jpg|png|webp|gif>`
- `update-check.json`

SQLite-Tabellen:

- `app_meta(key, value_json)`
- `boards(id, board_json)`
- `keycap_sets(id, keycap_set_json)`
- `artisan_sets(id, artisan_set_json)`
- `switch_sets(id, switch_set_json)`
- `photos(id, board_id, owner_type, owner_id, name, type, width, height, added_at, file_name)`

V1 speichert Kerndatensätze als JSON-Blobs. Das erleichtert Rückwärtskompatibilität, erzwingt aber Beziehungen und Konsistenz in UI-Code. V2 normalisiert diese Beziehungen.

### V1-Schutzgrenzen und Limits

- IDs: ausschließlich ASCII-Buchstaben, Zahlen, `_` und `-`.
- Maximal 10.000 Einträge je Inventartyp, 50.000 Fotos.
- Maximal 30 MiB je Foto, 500 MiB Fotodaten je Backup/Import, 100 MiB Metadaten beim vollständigen Ersetzen.
- Unterstützte Bildtypen: JPEG, PNG, WebP und GIF.
- Importierte Fotos werden auf maximal 1920 × 1080 Pixel skaliert.
- ZIP-Import akzeptiert Manifest-Schema 3, 4, 5 und 6; JSON-Backups werden weiterhin geöffnet.
- Vollständiger Import ersetzt den Bestand erst nach Validierung und verwendet für Fotos Staging/Backup-Verzeichnisse.
- Verwaiste Fotos werden beim Start entfernt.

### V1-Regressionsabdeckung

Die Referenz enthält Integrationstests für:

- Fenster-Schließen,
- Update-Service und Update-UI,
- ZIP-Backup-Export,
- PDF-/XLSX-Bestandsberichte,
- Foto-Normalisierung und Großansicht,
- SQLite-Speicher,
- Migration von IndexedDB/localStorage,
- schnelle Spotlight-Wechsel,
- Keycap-/Artisan-Verwaltung,
- Switch-Verwaltung einschließlich `3 PIN`, `5 PIN` und `HE`,
- bidirektionale Board-/Komponenten-Verknüpfungen,
- Rückkehr vom Editor zur Übersicht,
- natives Kontextmenü.

Diese Tests werden nicht kopiert. Ihre fachlichen Zusagen werden in native Unit-, Repository-, Migrations- und UI-Tests übersetzt.

## Zielarchitektur V2

### Plattform und Projektform

- Native macOS-App mit Swift 6 und SwiftUI.
- Mindestziel: macOS 14.0.
- Xcode-Projekt: `KeyboardManager.xcodeproj`.
- Haupttarget: `KeyboardManager`; Testtarget: `KeyboardManagerTests`.
- Hauptfenster als `WindowGroup`, separate native `Settings`-Szene.
- Projektlokaler Build-/Run-Einstieg: `script/build_and_run.sh`.
- Gepinnte Swift-Package-Abhängigkeit: ZIPFoundation 0.9.20 für eintragsweises, begrenztes ZIP-Lesen.

### Schichten

```text
SwiftUI Views / Commands / Settings
              │
        InventoryStore (@MainActor, @Observable)
              │
     InventoryRepository protocol
       ┌──────┴────────┐
SQLiteRepository   InMemoryRepository
       │
 Application Support / Fotos

V1 Source ──> V1MigrationService ──> validierter Snapshot ──> Repository
```

- **Views:** reine Darstellung, Navigation und native Nutzerinteraktion.
- **InventoryStore:** App-weiter UI-Zustand, Auswahl, Lade-/Fehlerzustände und Use-Case-Orchestrierung.
- **Models:** `Sendable`, `Codable`, wertorientiert und unabhängig von SwiftUI/SQLite.
- **Repository:** einzige schreibende Grenze für Inventardaten.
- **Migration Service:** nur lesender V1-Adapter, Transformation, Validierung und Protokoll.
- **Photo Service (ab Phase 1):** Import, Metadaten, Skalierung, Thumbnail-Cache und atomare Dateibewegungen.
- **Export/Backup Services (später):** bauen auf einem unveränderlichen `InventorySnapshot` auf.

### Zustandsbesitz

- App-weit: ein `InventoryStore` im App-Einstieg.
- Fensterweit: Route und Auswahl im Store; eine spätere Mehrfenster-Iteration kann Auswahl in Szenenzustand abspalten.
- Dauerhafte Einstellungen: `@AppStorage` nur für UI-Präferenzen; fachliche Einstellungen gehören ins Repository.
- Editorentwürfe: eigene Werttypen pro Editor, erst nach Validierung in den Store übernehmen.

## Datenmodell V2

### Kernobjekte

`Board`

- stabile String-ID zur verlustfreien V1-Übernahme
- Name, Hersteller, Format, Plate, PCB, Stabilisatoren, Bemerkung
- optionale Keycap-Set-ID
- Legacy-Anzeigetexte für Keycaps/Switches während der Migration
- Foto-IDs, Hauptfoto-ID, Erstellungs-/Änderungszeitpunkt

`KeycapSet`

- Name, Hersteller, Profil, Material, Status
- Kits, Quelle/Shop, HTTPS-Link, Notizen
- Legacy-Montagehinweis, externe Bild-URLs und Trello-Provenienz
- Fotos und Zeitpunkte

`ArtisanSet`

- analoges Sammlungsmodell mit Tags statt Kits

`SwitchSet`

- Typ, Housing-/Stem-Materialien, Feder, Wege und Kräfte
- Pins als geschlossener Typ: `three`, `five`, `hallEffect`
- LED-Diffusor, werkseitige Schmierung, Gesamtbestand
- Import-Provenienz und Importwarnungen
- Fotos und Zeitpunkte

`SwitchInstallation`

- normalisierte n:m-Beziehung zwischen Switch-Set und Board
- Menge je Board
- ersetzt die in V1 doppelt gepflegten Felder `switchSetIds`, `switchSetQuantities`, `mountedBoardId`, `mountedQuantity` und `installations` als kanonische Quelle

`PhotoRecord`

- ID, typisierter Besitzer, Originalname, MIME-Typ, Pixelmaß, Zeitpunkt, relativer Dateiname
- JPEG, PNG, WebP, GIF und HEIC; der tatsächliche ImageIO-Typ ist maßgeblich
- Binärdaten bleiben außerhalb der Datenbank

`InventorySnapshot`

- unveränderliche, konsistente Gesamtsicht auf alle Domänenobjekte
- Austauschformat zwischen Repository, Migration, Backup und Export

### Beziehungskonsistenz

- Ein Foto gehört exakt einem zulässigen Besitzer.
- Ein Hauptfoto muss in den Foto-IDs des Besitzers enthalten sein.
- Board-/Komponenten-Referenzen müssen auf existierende IDs zeigen oder bei Migration als Warnung protokolliert werden.
- Mengen sind nicht negativ.
- `availableQuantity = max(total - installed, 0)`.
- V1-IDs bleiben erhalten; neue V2-IDs werden als UUID-Strings erzeugt.
- V1-Felder, die nicht direkt in der UI sichtbar sind, werden nicht still verworfen. Sie werden transformiert oder in der Migrationsprovenienz erhalten.

## Phase-0-Grundgerüst

Das erste native App-Bundle demonstriert bereits:

- macOS-Systemfenster mit nativer Sidebar und Detailbereich,
- Routen für Übersicht, Erfassen, Galerie und V1-Migration,
- vier Inventartypen und leere Bestandskennzahlen,
- Toolbar-Aktionen und `⌘N` für einen neuen Board-Entwurf,
- separate Einstellungen-Szene,
- Store-/Repository-Verkabelung mit leerem In-Memory-Repository,
- sichtbaren Phase-0-/Migrationsstatus,
- Unit-Tests für Kerninvarianten und Migrationsquellen.

## Phase-1A-Migrationsstand

Der native Migrationsbereich kann ein V1-Schema-6-ZIP auswählen und vollständig prüfen. Die Verarbeitung läuft außerhalb des Main Actors; die Oberfläche zeigt Fortschritt, Ergebniszahlen und gruppierte Validierungshinweise. Der normalisierte Snapshot bleibt ausschließlich im Arbeitsspeicher.

Der private V1.3.2-Export wurde erfolgreich erkannt: 54 Keyboards, 73 Keycap-Sets, 61 Artisans, 55 Switch-Sets und 301 Fotos. Er ist ohne blockierende Fehler importierbar. Festgestellte, bewusst sichtbare Warnungen sind 15 als JPEG deklarierte HEIC-Dateien, vier nur switchseitig gespeicherte Installationsbeziehungen und drei erhaltene V1-Importhinweise.

## Phase-1B-Persistenz und Aktivierung

Der App-Start lädt jetzt aus `SQLiteInventoryRepository`. Fehlt die Datenbank, bleibt die Sammlung leer, ohne dabei Dateien anzulegen. Ein Speichervorgang schreibt genau einen versionierten, `Codable`-basierten `InventorySnapshot` innerhalb einer SQLite-Transaktion und prüft ihn anschließend durch Rücklesen und `PRAGMA integrity_check`.

Der bestätigte Import verwendet:

```text
~/Library/Application Support/de.r3d42.KeyboardManagerV2/
  Current/
    inventory.sqlite
    Photos/
    Thumbnails/          # regenerierbarer Cache ab Phase 3
    MigrationReport.json
  Backups/<migration-id>-previous/
  MigrationReports/<migration-id>.json
  Staging/<migration-id>/
```

Die Quelle wird zunächst als `Staging/<migration-id>/Source.zip` oder `Source.json` kopiert. Legacy-JSON wird dort reproduzierbar in ein internes `Canonical.zip` mit getrennten Fotodateien überführt. Nur die erneut validierte Staging-Kopie wird extrahiert. Ein vorhandener `Current`-Ordner wird vor der Aktivierung nach `Backups` verschoben. Schlägt die anschließende Aktivierung oder Berichtskopie fehl, wird der vorherige Ordner automatisch zurückverschoben.

Der komplette private Export wurde in einem temporären V2-Layout erfolgreich committed und wieder aus SQLite gelesen. Ein separater Fehlerinjektionstest beweist die Wiederherstellung des vorherigen `Current`-Bestands.

## Phase 2 – Native Erfassung und Bearbeitung

Phase 2 verbindet alle vier fachlichen Editoren mit dem produktiven SQLite-Repository:

- Anlegen, Bearbeiten und bestätigtes Löschen von Boards, Keycap-Sets, Artisans und Switch-Sets,
- typabhängige Pflichtfeld-, HTTPS-, Referenz-, Hauptfoto- und Mengenvalidierung,
- normalisierte Keycap-/Board-Beziehungen und Switch-Installationen ohne doppelte Wahrheit,
- wiederverwendbare, frei ergänzbare Bibliothekswerte aus V1 und neuen Eingaben,
- lokale Fotoauswahl mit ImageIO-Typprüfung, 30-MiB-Grenze und Skalierung auf maximal 1920 × 1080 Pixel,
- atomare Ablage neuer Fotos mit Rücknahme bei fehlgeschlagenem SQLite-Commit,
- native Übersichtstabelle mit Suche, Herstellerfilter, Sortierung, Doppelklick und Kontextaktionen,
- Live-Vorschau, Hauptfotoauswahl, sichtbare Speicher-/Fehlerzustände, `⌘S`, Text-Undo und Verwerfbestätigung beim Navigieren.

Die Editorlogik ist als reine Snapshot-Transformation von SwiftUI getrennt und wird zusammen mit Fotoablage, Beziehungen, Löschkaskaden und der bestehenden Migration getestet. Phase 2 schreibt ausschließlich in den V2-`Current`-Bestand.

Das Hauptfenster startet mit 1600 × 900 Punkten und bleibt bis zur Mindestgröße 980 × 640 nutzbar. Formular und Vorschau teilen ausschließlich die tatsächlich verfügbare Breite; dadurch bleiben Sidebar und Speicheraktionen auch in kompakten Fenstern vollständig sichtbar.

## Phase 3 – Galerie, Spotlight und erweiterte Filter

Phase 3 verbindet die persistierten Inventardaten mit einer medienorientierten nativen Darstellung:

- adaptives Galerie-Grid für Boards, Keycap-Sets und Artisans mit Hauptfoto, Kerndaten und Fotozahl,
- Spotlight-Großansicht für alle vier Inventartypen mit vollständiger lokaler Fotoansicht, Thumbnail-Leiste, Vor-/Zurück-Navigation, Escape, Bearbeiten und bestätigt Löschen,
- sichere Öffnung vorhandener HTTPS-Quellen aus dem Detailbereich,
- kombinierbare Filter für Hersteller/Format, Hersteller/Profil/Status sowie Switch-Typ/Betätigungskraft/Pins,
- diakritik-, breiten- und großkleinschreibungsunabhängige Volltextsuche,
- typabhängige stabile Sortierungen einschließlich Switch-Menge,
- lokaler 640-Pixel-Thumbnail-Cache unter `Current/Thumbnails`, der Originalfotos unverändert lässt und bei gelöschten Fotos mitbereinigt wird.

Präsentations- und Filterlogik sind von SwiftUI getrennt und mit kombinierten Filterfällen, `HE`-/Pin-Auswahl, Mengensortierung sowie realer ImageIO-Thumbnail-Erzeugung getestet.

## Phase 4 – Backup und Berichte

Phase 4 umfasst das portable Schema-6-ZIP-Backup:

- nativer Speichern-Dialog und jederzeit erreichbare Toolbar-Aktion,
- vollständige V1-kompatible Abbildung von Metadaten, Bibliothekswerten, allen vier Inventartypen, Beziehungen und Fotos,
- stabile Sortierung, sortierte JSON-Schlüssel sowie explizite ZIP-Zeitstempel und Dateirechte für reproduzierbare Archive,
- unveränderte Übernahme von JPEG, PNG, WebP und GIF,
- HEIC-Originale bleiben im V2-Fotoordner bytegenau erhalten und werden ausschließlich für die V1-kompatible Exportkopie als JPEG kodiert,
- 30-MiB-Einzellimit, 500-MiB-Gesamtlimit, sichere IDs und interne Dateinamen,
- Schreiben in eine temporäre Datei im Zielordner, vollständige Kontrolle mit dem vorhandenen Schema-6-Reader und erst danach atomare Installation am gewählten Ziel,
- sichtbarer Arbeits-, Erfolgs- und Fehlerzustand in der App.

Die Exporttests decken den V2→ZIP→V2-Rundlauf, unveränderte Quelldateien, den Schema-6-Dateiaufbau, fehlende Fotos, HEIC-Kompatibilität und Byteidentität bei gleichem Snapshot und Exportzeitpunkt ab.

Die historischen V1-Importquellen sind ebenfalls produktiv angebunden:

- ZIP-Schema 3, 4, 5 und 6 werden durch denselben gehärteten Reader geprüft; fehlende jüngere Inventartypen werden als leere Bestände übernommen,
- Schema-3-Fotos ohne `ownerType`/`ownerId` werden wie in V1 über `boardId` zugeordnet,
- Legacy-JSON ohne Schema sowie mit Schema 1 oder 2 wird nur lesend geöffnet; eingebettete Base64-Fotos werden ausschließlich in einem V2-eigenen temporären bzw. Staging-Archiv getrennt,
- vor einem Commit werden Originalhash, normalisierter Snapshot, Foto-Stagingplan, CRC, Bildtyp und Größen erneut verglichen,
- UI und Abschlussbericht zeigen den tatsächlichen Quelltyp; ZIP und JSON verwenden denselben Bestätigungs-, Backup- und Rollbackpfad.

Die Tests beweisen die Byte-Unverändertheit der JSON-Quelle, den vollständigen JSON-Commit mit Foto, die Schema-3–5-Normalisierung und weiterhin den privaten V1.3.2-Vollimport.

Die nativen Bestandsberichte schließen den zweiten Exportblock der Phase ab:

- gemeinsames, SwiftUI-unabhängiges Berichtsmodell mit den vollständigen V1-Spalten und den normalisierten V2-Beziehungen,
- nativer PDF-Bericht im A4-Querformat mit Deckblatt, Bereichsseiten, wiederholten Tabellenköpfen, Fußzeile, Seitenzahl und bis zu 200 lokalen Hauptfotos,
- native XLSX-Arbeitsmappe ohne Electron/Node-Laufzeit mit Übersichtsblatt und einem Blatt je exportiertem Inventartyp,
- formatierte Titel- und Kopfzeilen, abwechselnde Zeilenfarben, feste Spaltenbreiten, eingefrorene Kopfzeilen, Autofilter, typisierte Zahlen und Datumswerte sowie klickbare HTTPS-Links,
- atomare Zieldatei, Signatur-/Paketprüfung und sichtbare Arbeits-, Erfolgs- und Fehlerzustände,
- nativer Exportdialog für Format, gesamten oder aktuellen Bereich, Filter und PDF-Vorschaubilder.

**Filtersemantik:** „Aktueller Inventartyp“ exportiert ausschließlich den sichtbaren Typ. „Gesamter Bestand“ exportiert alle vier Typen. Aktive Filter und Sortierungen werden je Typ behalten; bei aktivierter Option wendet ein Gesamtexport deshalb die zuletzt gesetzten Filter jedes Typs an. Ohne diese Option werden sämtliche Einträge exportiert, die gewählte Sortierung bleibt bestehen.

Die Berichtstests prüfen Bereichs-/Filterauswahl, Beziehungen, typisierte Switch-Mengen, PDF-Signatur und -Seiteninhalt, fünf XLSX-Blätter, Freeze-Panes, Autofilter und HTTPS-Beziehungen. Zusätzlich wurden alle PDF-Seiten mit Poppler gerendert und alle XLSX-Blätter mit `artifact_tool` importiert, auf Fehler geprüft und visuell gerendert. Die Laufzeitprüfung bestätigte den Exportdialog einschließlich deaktivierter Bildoption bei XLSX und die feste untere Aktionsleiste auch bei leerem Bestand.

## Phase 5 – Qualität und Fensterzustände

Phase 5 ergänzt die noch fehlende Absicherung der nativen Oberfläche:

- ein AppKit-Window-Delegate-Adapter fängt den roten Fensterschalter ab, ohne die übrige SwiftUI-Fensterverwaltung zu ersetzen,
- bei einem geänderten Editor bleibt das Fenster offen und bietet „Weiter bearbeiten“ oder „Änderungen verwerfen und schließen“ an; ein sauberer Editor schließt ohne Zwischendialog,
- die UI-Tests verwenden pro Lauf einen eigenen temporären Application-Support-Bereich und verändern weder den echten V2-Bestand noch V1,
- die native UI-Automation prüft die sichtbare Reihenfolge **Übersicht → Galerie → Erfassen**, den kompletten Schließen-/Abbrechen-/Verwerfen-Ablauf und einen Accessibility-Audit der Übersicht,
- technische SF-Symbolnamen werden nicht mehr als Beschriftungen vorgelesen; Bestandskarten behalten stattdessen ihre sichtbaren Texte und Zahlen,
- ein XCTest-Performance-Benchmark misst kombinierte Suche und Sortierung auf 5.000 synthetischen Board-Datensätzen.

Für UI-Automation wird ein frisch erzeugter, lokal signierter Test-Runner verwendet. Ein unsignierter `KeyboardManagerUITests-Runner.app` ist kein auslieferbares Produkt und wird von macOS erwartungsgemäß blockiert; der produktive Test-Bundle bleibt `dist/Keyboard Manager.app`.

Abnahme am 23. Juli 2026:

- 43 Unit-, Repository-, Migrations-, Export- und Performance-Tests erfolgreich,
- 2 native UI-Tests erfolgreich,
- Xcode-Projektdatei mit `plutil` validiert,
- vollständiger UI-Test ohne Zugriff auf Nutzerdaten.

## Fachliche Restparität – direkte V1-SQLite-Quelle

Der erste Restparitätsblock ergänzt den produktiven Migrationsassistenten um die manuelle Auswahl eines V1-Datenordners mit `keyboard-manager.sqlite` und `photos/`:

- die regulären Quelldateien DB, WAL und SHM werden ausschließlich byteweise in V2-eigenes temporäres bzw. Commit-Staging kopiert; SQLite öffnet die Originalquelle nie,
- die SQLite Backup API öffnet ausschließlich die V2-eigene staged Dateifamilie schreibbar, damit SQLite ihren Snapshot konsistent erzeugen kann; die Originalquelle bleibt dabei vollständig unangetastet, einschließlich noch nicht eingecheckter WAL-Inhalte,
- ausschließlich diese V2-eigene Kopie wird auf Integrität geprüft, gelesen und in ein internes kanonisches Schema-6-Archiv überführt,
- Entitäts-IDs, Metadaten, Fotobesitzer, sichere Dateinamen, Einzel-/Gesamtgrößen und Bildinhalte durchlaufen danach denselben gehärteten Reader wie ZIP-Backups,
- ein deterministischer logischer SHA-256-Wert umfasst das normalisierte Manifest und alle referenzierten Fotobytes,
- vor dem Commit werden Quellhash, Snapshot und Foto-Stagingplan erneut erzeugt und verglichen; eine seit dem Prüflauf veränderte Quelle blockiert die Aktivierung,
- der bestätigte Import verwendet unverändert den vorhandenen SQLite-/Foto-/Backup-/Rollbackpfad.

Die Oberfläche fordert dazu auf, V1 vor der direkten Prüfung vollständig zu beenden. Die automatische Erkennung prüft die bekannten Electron-App-Support-Namen `keyboard-manager`, `Keyboard Manager` und `com.keyboard.manager`. Zur Schemaerkennung werden Datenbank, WAL und SHM ausschließlich in einen V2-eigenen temporären Bereich kopiert; SQLite öffnet dabei nie die Originalquelle. Läuft eine App mit der V1-Bundle-ID `com.keyboard.manager`, zeigt V2 den gefundenen Pfad an, blockiert aber Prüflauf und Commit bis zu einer erneuten Suche nach dem Beenden.

Fünf direkte SQLite-Tests und drei Discovery-Tests verwenden echte synthetische WAL-Datenbanken. Sie belegen wiederholbare Prüfung, vollständige Übernahme noch nicht eingecheckter WAL-Inhalte, bytegenau unveränderte Datenbank-/WAL-/SHM-/Fotodateien, vollständigen Commit, Prozesssperre und die Sperre nach einer Quelländerung. Der reale private V1-Export bleibt über den bestehenden ZIP-Integrationstest abgedeckt; private Live-SQLite-Daten werden nicht als Testfixture verwendet.

Aktueller Abnahmestand:

- 55 Unit-, Repository-, Migrations-, Export- und Performance-Tests erfolgreich,
- 3 native UI-Tests erfolgreich,
- direkte SQLite-Quelle einschließlich WAL/SHM und Fotos vor und nach Prüfung/Commit bytegenau unverändert,
- keine automatische Änderung, Verschiebung oder Bereinigung im V1-Verzeichnis.

## Fachliche Restparität – externe Importbilder

V1 verwendet bei Keycap-Sets und Artisans `coverUrl` und `externalImageUrls` automatisch als Galerie-, Spotlight- und Vorschaubilder, sobald kein lokales Foto vorhanden ist. V2 erhält die Anzeigeparität mit einer bewusst lokalen Datenschutzgrenze:

- Galerie und Spotlight zeigen Anzahl und Zustand vorhandener externer Importbilder, lösen dabei aber keinen Netzwerkabruf aus.
- Der Editor nennt vor dem Download die betroffenen Hosts und verlangt eine ausdrückliche Bestätigung.
- Die ephemere Download-Sitzung verwendet weder Cookies noch persistenten URL-Cache und akzeptiert ausschließlich HTTPS, auch über Weiterleitungen.
- HTTP-Status, finale URL, Bild-MIME, 30-MiB-Einzellimit und tatsächliche ImageIO-Dekodierbarkeit werden geprüft; große gültige Bilder durchlaufen dieselbe 1920-×-1080-Skalierung wie lokale Importe.
- Geladene Bilder bleiben bis zum normalen Speichern vorbereitete, unpersistierte Fotos. Verlassen, Abbruch oder Verwerfen beendet einen laufenden Abruf und lässt Bestand sowie externe Metadaten unverändert.
- Erst der normale atomare Foto-/SQLite-Speicherpfad übernimmt die Dateien lokal. Die nun ersetzten externen Bildadressen werden im Entwurf entfernt, damit keine unbemerkten Folgeabrufe oder Doppelimporte entstehen.

Vier neue Tests decken HTTPS-vor-Netzwerk, Deduplizierung, sichere Endadresse/MIME, ImageIO-Aufbereitung sowie die getrennte Darstellung lokaler und externer Fotozahlen ab.

## Fachliche Restparität – Deutsch/Englisch

V2 besitzt nun dieselbe fachliche Sprachauswahl wie V1, umgesetzt mit nativer SwiftUI-Lokalisierung:

- Deutsch ist die deklarierte Bundle- und String-Catalog-Quellsprache; Englisch wird als vollständige `en.lproj`-Lokalisierung gebaut.
- Die Einstellung wirkt ohne Neustart auf Hauptfenster, Einstellungen, Fachbezeichnungen, Migrationszustände, Fehlermeldungen sowie PDF-/XLSX-Berichte.
- `@AppStorage` hält die lokale UI-Präferenz. Beim ersten V2-Start wird eine aus V1 migrierte Sprache übernommen; danach gewinnt die ausdrücklich in V2 gewählte Sprache und wird zusätzlich im SQLite-Snapshot gespeichert.
- Berichtsinhalte, Zahlen und Datumswerte verwenden die im Snapshot gespeicherte Sprache und Locale, damit ein Export während der Erzeugung konsistent bleibt.
- Der Katalog umfasst 385 deutsch-englische Schlüssel. `tools/update_localizations.cjs` kontrolliert sowohl alle Katalogeinträge als auch alle im Swift-Code verwendeten `L10n.text`-Schlüssel auf eine englische Übersetzung.
- Ein Laufzeittest prüft beide Sprachpfade, ein Store-Test die normalisierte SQLite-Persistenz und ein nativer UI-Test die tatsächlich englisch dargestellte Oberfläche.

Die zwei optionalen Integrationstests des privaten, 196 MiB großen V1-Exports verwenden bevorzugt dessen byteidentische Kopie unter `/private/tmp/keyboard-manager-private-v1-export.zip`; alternativ lässt sich ein Pfad über `KEYBOARD_MANAGER_PRIVATE_V1_EXPORT` setzen. So öffnet der XCTest-Host keine private Quelldatei direkt auf einem externen Datenträger; der Originalexport und V1 bleiben unverändert.

## Fachliche Restparität – Rückkehr nach Bearbeiten

Wie V1 kehrt V2 nach dem Speichern oder bestätigten Verwerfen eines bearbeiteten Eintrags zur vorherigen Bestandsübersicht zurück:

- Filter und Sortierung werden je Inventartyp im laufenden Fenstersitzungszustand gehalten, statt beim Wechsel zum Editor neu angelegt zu werden.
- Der bearbeitete Eintrag bleibt ausgewählt. Die vor dem Editorwechsel erfasste Pixel-Scrollposition wird beim Rückweg wieder angewendet.
- Eine kleine, auf die fünfsäulige Bestandstabelle begrenzte AppKit-Brücke übernimmt den unter macOS 14 in SwiftUI fehlenden imperativen Rand: `NSTableView` lokalisieren, `NSClipView` scrollen und die Tabelle wieder zum First Responder machen.
- Der Wiederherstellungsauftrag wird nach einmaliger Anwendung verbraucht; spätere normale Ansichtswechsel erzwingen keinen veralteten Scrollstand.
- Store-Tests prüfen Speichern und Verwerfen einschließlich Filter, Sortierung, Auswahl und Scrollkontext. Ein fensterloser AppKit-Integrationstest prüft zusätzlich Pixeloffset und First Responder.
- Die Rückkehrfunktion ist von einer späteren Neuanlage getrennt: Wird „Erfassen“ regulär über die Sidebar geöffnet, löscht V2 die aktive Editor-ID und erzeugt für den aktuell gewählten Inventartyp einen leeren Entwurf. Die Auswahl der Übersicht bleibt davon getrennt erhalten.

## Fachliche Restparität – V1-Übersichtstabellen

Die vier Bestandsübersichten zeigen wieder die für V1 wesentlichen Fachinformationen, beziehen sie aber aus den normalisierten V2-Beziehungen:

- Keyboards zeigen Keycaps sowie alle verbauten Switch-Sets mit jeweiliger Menge.
- Keycap-Sets zeigen Kits und das montierte Board; Artisans zeigen Tags und Board.
- Switch-Sets zeigen `Bestand / Verbaut / Verfügbar` sowie alle Boards mit installierter Menge.
- Jede Tabelle besitzt eine lokale Fotovorschau aus dem Thumbnail-Cache. Fehlt ein hochgeladenes Bild oder kann es nicht geladen werden, erscheint ein nativer, nicht persistierter Platzhalter mit Fotosymbol und „Kein Foto“.

Zwei Präsentationsmodelltests sichern die Beziehungen einschließlich der Legacy-Namensfallbacks. Die vier Tabellen wurden zusätzlich im laufenden App-Prozess mit dem importierten Bestand geprüft.

## Fachliche Restparität – Kontextmenü, Übersichtskopf und App-Icon

Die allgemeine macOS-Interaktion und der Übersichtskopf wurden abschließend bereinigt:

- Ein app-weites SwiftUI-Kontextmenü leitet Rückgängig, Wiederholen, Ausschneiden, Kopieren, Einfügen und Alles auswählen an die native AppKit-Responder-Kette weiter. Nicht verfügbare Aktionen bleiben wie in macOS üblich deaktiviert.
- Spezialisierte Tabellen- und Galeriemenüs bleiben erhalten und ergänzen die aktive Aktion „Name kopieren“. Editierbare Textfelder verwenden weiterhin ihr vollständiges natives AppKit-Menü.
- Die Übersicht reserviert keine künstlichen 350 Punkte mehr für einen leeren vertikalen Scrollbereich. Kennzahlen, Inventartyp und Filter bestimmen ihre tatsächliche Höhe; die Tabelle schließt unmittelbar an.
- Der interne Sammelbegriff „Fachfeld“ erscheint nicht mehr in der Sortierung. Je nach Inventartyp lautet die Option konkret „Format“, „Profil“ oder „Typ“.
- Ein eigener macOS-AppIcon-Katalog enthält alle Auflösungen von 16 bis 1024 Pixel. Xcode baut daraus `AppIcon.icns`; das lokal gebaute Bundle trägt das neue Tastatur-/Bestandsmotiv.
- Die selten benötigte Sidebar-Gruppe „Daten“ nutzt eine native Disclosure-Section. Sie ist für neue Nutzende zunächst geschlossen, merkt sich den gewählten Zustand und klappt sich bei gezielter Navigation zur V1-Migration selbst auf.
- In der geöffneten Großbildansicht wechseln die unmodifizierten Pfeiltasten ← und → ausschließlich zwischen den lokalen Fotos des aktuellen Eintrags. Der hinterlegte Spotlight-Befehl wird währenddessen bewusst auf die Fotoauswahl umgeleitet.

Der vollständige Satz von 66 Unit-/Integrations-/Performance-Tests und alle 4 lokal signierten UI-Tests sind grün. Layout, typabhängige Sortieroptionen, globale und spezialisierte Kontextmenüs sowie der leere Neuanlage-Editor wurden zusätzlich im laufenden App-Prozess geprüft.

## Phase 6 – Produktisierung und Veröffentlichung

Mit Beauftragung am 26. Juli 2026 beginnt nach abgeschlossener fachlicher Restparität die getrennte Produkt- und Releasephase:

- `RELEASE.md` dokumentiert Produktidentität, einen lokalen Developer-ID-/Notarisierungspfad, die GitHub-Secrets und die unabhängige Artefaktprüfung.
- `script/release.sh` erzeugt ein universelles Releasearchiv, signiert und notarisiert das DMG, stapelt das Ticket und ruft die Prüfung des **tatsächlich ausgelieferten** Containers auf. `script/verify_release.sh` prüft DMG und darin enthaltene App erneut.
- CI führt ausschließlich die nicht-interaktiven Unit-/Integrations-/Performance-Tests aus. UI-Tests dürfen nie mit `CODE_SIGNING_ALLOWED=NO` gestartet werden: Der dann unsignierte `KeyboardManagerUITests-Runner.app` wird von macOS als beschädigt blockiert. Sie benötigen frisches DerivedData, lokale Signierung und eine entsperrte interaktive Sitzung.
- Eine lokale Developer-ID-Identität ist vorhanden. Ein Universal-Releasearchiv wurde erfolgreich gebaut; `codesign --verify --deep --strict` bestätigt die App, die Bundle-ID `de.r3d42.KeyboardManagerV2`, Hardened Runtime und beide Architekturen `x86_64 arm64`.
- Lizenz, Datenschutz- und Drittanbieterhinweise sowie GitHub-CI-/Releasevorlagen liegen im Repository bereit. Das lokale V1-Notarisierungsprofil wird nicht wiederverwendet; V2 verwendet das separate Profil `keyboardmanager-new-notary`.
- Das Releaseartefakt `dist/release/Keyboard-Manager-1.0.0-universal.dmg` des CI-Fix-Commits wurde am 27. Juli 2026 mit Submission-ID `448cec81-4726-4839-a2f6-d54a2ff77115` von Apple akzeptiert und gestapelt. Die erneute Prüfung des exakten DMG und der darin enthaltenen Universal-App bestätigt `source=Notarized Developer ID`; SHA-256: `6d4498f82d14a2bd331d5b433fe06d0a7f43f1d10599f2c9d126826987686e8e`.

## Öffentliche Erstveröffentlichung

Die Erstveröffentlichung ist abgeschlossen:

- Das öffentliche Repository liegt unter `https://github.com/c5vcpq5gsr-alt/keyboard-manager-new`; seine öffentliche Historie enthält einen anonymisierten Initial-Commit und keine lokalen Build-, Release-, Backup- oder Finder-Dateien.
- `main` schützt gegen Löschen und Force-Pushes, erzwingt lineare Historie und Gesprächsauflösung.
- Das Tag `v1.0.0` veröffentlicht `Keyboard-Manager-1.0.0-universal.dmg` sowie die SHA-256-Datei unter `https://github.com/c5vcpq5gsr-alt/keyboard-manager-new/releases/tag/v1.0.0`.
- Ein frischer GitHub-Download stimmt bytegenau mit der lokalen SHA-256 `6d4498f82d14a2bd331d5b433fe06d0a7f43f1d10599f2c9d126826987686e8e` überein und besteht erneut Signatur-, Staple-, Gatekeeper-, Container- und eingeschlossene-App-Prüfung als `source=Notarized Developer ID`.
- GitHub CI ist für den Release-Stand grün. Der tagbasierte Release-Workflow überspringt die CI-Notarisierung erfolgreich, bis die dokumentierten Zertifikats- und App-Store-Connect-Secrets hinterlegt sind; die veröffentlichte Erstversion wurde lokal notariell gebaut und unabhängig remote verifiziert.

Weitere Produktarbeit bleibt danach ausdrücklich möglich, insbesondere die protokollierte Bereinigung von Importwarnungen im Spotlight.

## Build und Test

```bash
cp keyboard-manager-backup.zip /private/tmp/keyboard-manager-private-v1-export.zip
xcodebuild -project KeyboardManager.xcodeproj -scheme KeyboardManager -configuration Debug \
  -derivedDataPath /private/tmp/KeyboardManagerV2-Tests -parallel-testing-enabled NO \
  test -only-testing:KeyboardManagerTests
xcodebuild -project KeyboardManager.xcodeproj -scheme KeyboardManager -configuration Debug \
  -derivedDataPath /private/tmp/KeyboardManagerV2-Tests -parallel-testing-enabled NO \
  test -only-testing:KeyboardManagerUITests
./script/build_and_run.sh --build
./script/build_and_run.sh
```

Der deterministische lokale App-Bundle liegt nach dem Script unter `dist/Keyboard Manager.app`.
`--build` beendet keinen laufenden Prozess. Die Start-, Debug- und Prüfmodi beenden vor dem Neubau ausschließlich eine V2-Instanz, deren ausführbare Datei aus dem projektlokalen `dist`- oder DerivedData-Bundle stammt; eine gleichnamige Electron-V1 bleibt unangetastet.
