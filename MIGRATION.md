# Keyboard Manager V2 – Migration von V1

Stand: 23. Juli 2026 · ZIP-Schema 3–6, Legacy-JSON und direkte V1-SQLite-Quelle produktiv

## Sicherheitsziel

Eine Migration darf den V1-Bestand niemals verändern. V2 liest aus einer stabilen Quelle, kopiert in einen eigenen Staging-Bereich, transformiert und validiert dort und aktiviert den neuen Bestand erst nach einer expliziten Bestätigung. Jeder Abbruch muss V1 und einen bereits existierenden V2-Bestand unverändert lassen.

## Unterstützte Quellen

Priorität und empfohlener Einsatz:

1. **V1-ZIP-Backup (Schema 6, außerdem 3–5):** bevorzugter, portabler Weg; Manifest und Bilder liegen konsistent in einer Datei.
2. **Direkte V1-SQLite-Daten:** für eine installierte lokale V1; `keyboard-manager.sqlite` und `photos/` werden nur gelesen.
3. **Legacy-JSON-Backup:** weiterhin für ältere Exporte.
4. **IndexedDB/localStorage:** nur als Sonderfall über eine noch lauffähige V1 bzw. einen dedizierten Extraktor; V2 bindet keine WebView nur für diesen Speicher ein.

## Datenbereiche

V1-Quelle, typischer Kandidat auf macOS:

```text
~/Library/Application Support/keyboard-manager/
  keyboard-manager.sqlite
  keyboard-manager.sqlite-wal
  keyboard-manager.sqlite-shm
  photos/
```

V2 prüft diesen sowie zwei historische Namensvarianten automatisch und zeigt den erkannten Pfad im Assistenten an. Ein passender Verzeichnisname allein reicht nicht: Erst SQLite-Header, reguläre Pfade und das an einer V2-eigenen Kopie bestätigte V1-Schema machen den Kandidaten auswählbar. Die manuelle Ordnerauswahl bleibt als Alternative erhalten.

V2-Ziel:

```text
~/Library/Application Support/<V2 bundle identifier>/
  Current/
    inventory.sqlite
    Photos/
    Thumbnails/          # ab Phase 3; vollständig regenerierbarer Cache
    MigrationReport.json
  Backups/<migration-id>-previous/
  MigrationReports/<migration-id>.json
  Staging/<migration-id>/
    Source.zip | Source.json
    V1Source.sqlite[-wal|-shm]  # temporäre Kopie der direkten V1-Quelle
    V1Snapshot.sqlite           # konsistenter Backup-API-Snapshot
    Canonical.zip         # intern für Legacy-JSON oder direkte SQLite
    Current/
```

Bundle-ID und endgültiger Verzeichnisname werden vor Phase 1 festgeschrieben. Die Phase-0-ID `de.r3d42.KeyboardManagerV2` ist noch keine Releasezusage.

## Vorbedingungen für direkte SQLite-Migration

1. V1 anhand der Bundle-ID `com.keyboard.manager` prüfen und direkte Prüfung sowie Commit blockieren, solange sie läuft.
2. Die Oberfläche zeigt diese Vorbedingung und einen gefundenen, aber blockierten Kandidaten sichtbar an.
3. Bei WAL-Dateien niemals nur die Hauptdatei kopieren. Der produktive Reader kopiert DB, WAL und SHM in den V2-eigenen Bereich und erzeugt erst dort über eine V2-eigene Schreibverbindung und die SQLite Backup API einen konsistenten Snapshot.
4. Niemals Migrationstabellen, Pragmas oder Checkpoints in der Originaldatenbank ausführen.
5. Gesamtgröße, letzten Änderungszeitpunkt und deterministischen logischen SHA-256-Wert erfassen.

## Migrationspipeline

### 1. Quelle entdecken

- bekannte App-Support-Kandidaten nur lesend prüfen,
- manuelle Ordner-/Backup-Auswahl anbieten,
- Quelle und Typ sichtbar anzeigen,
- keine automatische Übernahme im Hintergrund.

### 2. Snapshot herstellen

- eindeutige Migrations-ID erzeugen,
- ZIP- oder JSON-Quelle in `Staging/<migration-id>/Source.<zip|json>` kopieren,
- Legacy-JSON-Fotos aus `dataUrl` ausschließlich in ein internes `Canonical.zip` unter Staging trennen,
- direkte SQLite-Quelle per SQLite Backup API in eine V2-eigene `V1Snapshot.sqlite` überführen und daraus mit den referenzierten Fotodateien ein internes `Canonical.zip` erstellen,
- Dateiliste und Hashes protokollieren,
- nur mit dem Snapshot weiterarbeiten.

### 3. Dekodieren und Grenzen prüfen

- maximal 10.000 Boards, Keycap-Sets, Artisans und Switch-Sets,
- maximal 50.000 Fotos,
- maximal 30 MiB pro Foto und 500 MiB gesamt,
- IDs gegen `^[A-Za-z0-9_-]+$` prüfen,
- ZIP-Einträge gegen Pfadtraversal schützen,
- MIME-Typ und tatsächliche Bilddekodierbarkeit vergleichen,
- ausschließlich HTTPS für externe URLs akzeptieren.

### 4. Transformieren

- V1-Zeitstempel in `Date` umwandeln, fehlende Werte protokolliert ergänzen.
- Board, Keycap, Artisan und Switch mit stabiler V1-ID übernehmen.
- V1-Statuswerte unverändert übernehmen; unbekannte Werte nicht still normalisieren.
- `pins`: `3` → `three`, `5` → `five`, `HE` → `hallEffect`; Unbekanntes als Warnung mit sicherem Fallback behandeln.
- `switchSetIds`, `switchSetQuantities`, `SwitchSet.installations`, `mountedBoardId` und `mountedQuantity` in eine kanonische Menge von `SwitchInstallation`-Datensätzen zusammenführen.
- Bei widersprüchlichen Mengen beide Quellen im Bericht nennen. Standardregel: explizite `installations` des Switch-Sets gewinnt; Board-Mengen ergänzen nur fehlende Beziehungen.
- Keycap-/Artisan-Montagebeziehungen mit Board-Referenzen abgleichen.
- `coverUrl`, `externalImageUrls`, `trelloCardId`, `trelloListName` und Switch-Importprovenienz erhalten.
- Legacy-Anzeigetexte (`keycaps`, `switches`) erhalten, bis die referenzierten Datensätze sicher aufgelöst sind.

### 5. Fotos übernehmen

- Besitzerreferenz vor Dateikopie validieren,
- Bild über ImageIO dekodieren,
- Metadaten und Dateityp überprüfen,
- Originaldatei in Staging kopieren; keine V1-Datei verschieben,
- V2-Dateiname aus ID und validiertem Typ bilden,
- Hauptfoto nur setzen, wenn es zur Foto-ID-Liste des Besitzers gehört,
- fehlende Dateien als Warnung protokollieren und nicht durch leere Platzhalter vortäuschen.

Eine erneute Skalierung ist bei direkten V1-Fotos normalerweise nicht erforderlich, wird aber geprüft. V2 darf vorhandene Qualität nicht durch wiederholtes JPEG-Encoding verschlechtern.

### 6. Snapshot validieren

Harte Fehler verhindern den Commit:

- doppelte oder ungültige IDs,
- nicht dekodierbare Pflichtstruktur,
- manipulierte ZIP-Pfade,
- Limitüberschreitung,
- Datenbank-/Dateisystemfehler,
- unmögliche Besitzertypen.

Warnungen erlauben eine bewusste Fortsetzung:

- verwaiste Referenzen,
- fehlende optionale Fotos,
- unbekannte Status-/Listenwerte,
- widersprüchliche alte Montageangaben,
- unsichere externe URL, die verworfen wurde.

### 7. Vorschau und Bestätigung

Vor dem Schreiben zeigt V2:

- Quelle und Snapshot-Zeitpunkt,
- Anzahl je Inventartyp und Fotos,
- Gesamtgröße,
- Fehler und Warnungen,
- Anzahl transformierter/verworfener Felder,
- Zielverzeichnis,
- Auswirkung auf einen bestehenden V2-Bestand.

Ein bestehender V2-Bestand wird nie ohne separate Bestätigung ersetzt. Vor dem Ersetzen erstellt V2 ein eigenes V2-Backup.

### 8. Atomarer Commit

- neue SQLite-Datenbank vollständig unter `Staging/<id>/Current` erzeugen,
- Snapshot zurücklesen und SQLite-Integritätsprüfung ausführen,
- Fotos vollständig unter `Staging/<id>/Current/Photos` ablegen und Größe/CRC prüfen,
- Abschlussbericht bereits im Staging-Bestand schreiben,
- bestehenden V2-`Current`-Ordner nach `Backups/<id>-previous` verschieben,
- geprüften Staging-`Current`-Ordner an die produktive Stelle verschieben,
- Bericht zusätzlich nach `MigrationReports/<id>.json` kopieren,
- bei einem Fehler nach dem Backup-Schritt den neuen Bestand entfernen und den vorherigen `Current`-Ordner zurückverschieben.

### 9. Abschlussbericht

Der Bericht ist lokal, enthält keine Bildinhalte und nennt:

- Migrations-ID, App-/Schema-Versionen und Zeitpunkte,
- Quell-/Zielpfad in nutzerlesbarer Form,
- Quellhashes,
- Zähler vorher/nachher,
- Warnungen, Fehler und gewählte Konfliktregeln,
- Ergebnis der SQLite- und Fotoprüfung.

## Wiederholbarkeit

- Migrationen sind durch eine ID und den Quellhash unterscheidbar.
- Derselbe Snapshot kann erneut als Probe validiert werden, ohne zu schreiben.
- Ein abgebrochener Staging-Bereich wird beim nächsten Start angeboten oder sicher bereinigt.
- V1 bleibt nach Erfolg weiterhin startbar und unverändert.
- Ein „Zurück zu V1“ bedeutet nur, V1 wieder zu öffnen; V2 exportiert nicht ungefragt zurück in V1.

## Direkte V1-SQLite-Quelle (fachliche Restparität)

Der Migrationsassistent akzeptiert einen manuell gewählten V1-Datenordner, der `keyboard-manager.sqlite` und bei referenzierten Fotos `photos/` enthält. Ordner, Datenbank, WAL-/SHM-Dateien und Fotos dürfen keine symbolischen Links sein; Datenbank einschließlich Sidecars sowie Fotoeinzel- und Gesamtgrößen unterliegen festen Grenzen.

Die Originaldatenbank wird nicht mit SQLite geöffnet. V2 kopiert die regulären Quelldateien `keyboard-manager.sqlite`, `-wal` und `-shm` zunächst byteweise in seinen eigenen temporären Bereich. Erst dort öffnet die SQLite Backup API ausschließlich die staged Dateifamilie schreibbar und schreibt einen konsistenten Snapshot. Nur V2-eigene Kopien dürfen Sidecars erzeugen und `PRAGMA integrity_check` ausführen. V2 liest daraus `app_meta`, alle vier Inventartabellen und die Foto-Metadaten, prüft Zeilen- gegen JSON-IDs und erzeugt ein kanonisches Schema-6-Manifest. Fotos werden anhand der Datenbankreferenzen nur gelesen, auf sichere Namen und Größen geprüft und gemeinsam mit dem Manifest durch den vorhandenen ZIP-Reader validiert.

Der angezeigte SHA-256-Wert ist bei dieser Quelle ein deterministischer Hash des logisch zu migrierenden Bestands: normalisiertes Manifest plus referenzierte Fotobytes. Beim bestätigten Import wird der Vorgang im Commit-Staging wiederholt. Nur wenn Quelltyp, Hash, Snapshot und Foto-Stagingplan exakt zum Prüflauf passen, beginnt der bestehende atomare Commit. V1 wird weder umbenannt noch beschrieben; V2 erzeugt keine Checkpoints oder Pragmas in der Originaldatenbank.

Beim Öffnen des Migrationsbereichs durchsucht V2 die nutzerspezifischen Application-Support-Pfade nach den bekannten V1-Verzeichnisnamen `keyboard-manager`, `Keyboard Manager` und `com.keyboard.manager`. Eine SQLite-Signatur allein reicht nicht: Die Erkennung prüft an einer V2-eigenen Kopie die sechs erwarteten Tabellen und den App-Metadatensatz. Symbolische Links werden nicht akzeptiert.

Vor Discovery, direktem Prüflauf und Commit wird die laufende V1 anhand der Bundle-ID `com.keyboard.manager` geprüft. Ist sie geöffnet, darf V2 nur Dateimetadaten und den SQLite-Header lesen, zeigt den Kandidaten sichtbar als blockiert an und verlangt nach dem Beenden eine erneute Suche. ZIP- und JSON-Importe bleiben davon unabhängig.

## Historische ZIP- und JSON-Quellen (Phase 4)

Der ZIP-Reader akzeptiert die von V1 selbst erlaubten Manifest-Schemata 3 bis 6. Schema 3 enthält Boards und boardgebundene Fotos; `ownerType` und `ownerId` werden deshalb aus `boardId` ergänzt. Spätere optionale Inventararrays werden bei älteren Schemata als leer behandelt. Alle Archive durchlaufen unverändert Pfad-, ID-, Eintrags-, Größen-, CRC-, Beziehungs- und ImageIO-Prüfungen.

Legacy-JSON wird nur als vollständiges V1-Objekt mit `boards` und `lists` akzeptiert. Unterstützt sind Dateien ohne Schemaangabe sowie Schema 1 und 2. Base64-`dataUrl`-Fotos müssen einen zu den Metadaten passenden unterstützten MIME-Typ besitzen und unterliegen den gleichen Einzel- und Gesamtlimits wie ZIP-Fotos. V2 schreibt daraus ein temporäres kanonisches Schema-6-Archiv; beim bestätigten Import entsteht dieses erneut aus der kopierten `Source.json` im Staging. Erst wenn Quellhash, Snapshot und Foto-Stagingplan mit dem Prüflauf übereinstimmen, beginnt der bestehende SQLite-/Foto-/Rollback-Commit.

Die ursprüngliche ZIP- oder JSON-Datei wird weder umbenannt noch verändert. Das kanonische Archiv gehört ausschließlich V2 und wird mit dem Staging-Verzeichnis entfernt.

## Portabler V2-Backup-Export (Phase 4)

V2 erzeugt für portable Sicherungen weiterhin das von V1 definierte ZIP-Schema 6:

```text
keyboard-manager-backup.zip
  manifest.json
  photos/<photo-id>.<jpg|png|webp|gif>
```

Das Manifest enthält App-Metadaten, Bibliothekswerte, die V1-Galerievorgaben, Boards, Keycap-Sets, Artisans, Switch-Sets, beide Seiten der normalisierten Switch-Installationen und Foto-Metadaten. Entitäten und ZIP-Einträge werden stabil nach ID geschrieben; JSON-Schlüssel, ZIP-Zeitstempel und Dateirechte sind festgelegt. Bei gleichem Snapshot, App-Versionswert und Exportzeitpunkt entsteht dadurch dasselbe Archiv.

Der Export liest ausschließlich aus dem aktiven V2-Snapshot und `Current/Photos`. JPEG, PNG, WebP und GIF werden ohne Änderung übernommen. HEIC gehört nicht zum V1-ZIP-Vertrag: Ein HEIC-Original bleibt deshalb im verwalteten V2-Ordner unverändert und wird nur für die Archivkopie als JPEG kodiert. Die Oberfläche meldet die Anzahl dieser Kopien.

Vor der Zielaktivierung gelten dieselben Grenzen wie beim Import: 10.000 Einträge je Inventartyp, 50.000 Fotos, 30 MiB pro Foto, 500 MiB Fotodaten und 10 MiB Manifest. Das Archiv entsteht als temporäre Datei neben dem Ziel, wird vollständig über `V1BackupReader` zurückgelesen und nur bei importierbarem Ergebnis und identischen Bestandszählern atomar am gewählten Ziel installiert. Eine fehlende Fotodatei oder eine fehlgeschlagene Prüfung hinterlässt kein scheinbar erfolgreiches Backup.

PDF- und XLSX-Bestandsberichte lesen denselben unveränderlichen V2-Snapshot, sind aber keine Migrations- oder Wiederherstellungsquellen. Sie verändern weder V1- noch V2-Daten. Beide Formate entstehen zunächst als temporäre Datei neben dem gewählten Ziel, werden formatbezogen geprüft und erst danach atomar installiert. Filter und Sortierung werden je Inventartyp aus der Übersicht übernommen; ihre Anwendung kann im Exportdialog vollständig abgeschaltet werden.

## Feldzuordnung

| V1 | V2 | Regel |
| --- | --- | --- |
| `boards.board_json` | `Board` + Beziehungen | Kernfelder direkt, Beziehungen normalisieren |
| `keycap_sets.keycap_set_json` | `KeycapSet` | URLs validieren, Provenienz erhalten |
| `artisan_sets.artisan_set_json` | `ArtisanSet` | Tags geordnet übernehmen |
| `switch_sets.switch_set_json` | `SwitchSet` + `SwitchInstallation` | Pins typisieren, Mengen konsolidieren |
| `photos` + `photos/<file>` | `PhotoRecord` + `Photos/<file>` | Besitzer/MIME/Datei gemeinsam validieren |
| `app_meta.app.meta` | `AppMetadata` | Sprache und Zeitpunkte übernehmen |
| `app_meta.app.lists` | `LibraryValues` | Nutzerwerte erhalten, Defaults dedupliziert ergänzen |
| `app_meta.app.gallery` | UI-Präferenzen | nur bekannte Felder übernehmen |
| `update-check.json` | nichts | nicht migrieren; V2 hat eigenen Updatezustand |

### Sprachmetadaten

`app_meta.app.meta.language` wird ausschließlich auf `de` oder `en` normalisiert und in `AppMetadata.preferredLanguage` übernommen. Existiert noch keine ausdrücklich gespeicherte V2-Präferenz, übernimmt die Oberfläche diesen Wert beim ersten Laden. Sobald in V2 eine Sprache gewählt wurde, ist diese lokale Präferenz maßgeblich und wird auch in den SQLite-Snapshot zurückgeschrieben; ein späteres Laden überschreibt sie nicht erneut mit einer älteren Migrationsquelle.

Die Sprache beeinflusst keine fachlichen IDs oder Beziehungen. Sie steuert ausschließlich Darstellung, Fehlermeldungen, Migrationshinweise sowie Locale und Beschriftungen neu erzeugter PDF-/XLSX-Berichte. Portable Schema-6-Backups schreiben den normalisierten Wert zurück in `meta.language`. Keine dieser Operationen verändert die V1-Metadaten.

## Teststrategie

- Golden fixtures für ZIP-Schemas 3, 4, 5 und 6.
- Legacy-JSON mit eingebettetem Foto, byte-identischer Quelle und vollständigem Commit.
- direkter SQLite-Fixturebestand mit WAL.
- Discovery-Fixtures für gültiges V1-Schema, gleichnamige Fremddatenbank und laufenden V1-Prozess.
- leere, große, beschädigte und widersprüchliche Bestände.
- alle vier Foto-Besitzertypen und alle unterstützten Bildformate.
- doppelte IDs, fehlende Dateien, Path Traversal und falsche MIME-Angaben.
- `3`/`5`/`HE`, mehrere Switch-Sets je Board und widersprüchliche Mengen.
- zweimaliger Probeimport liefert denselben normalisierten Snapshot.
- erzwungener Fehler in jeder Commit-Stufe beweist Rollback.
- Quellverzeichnis ist vor und nach jedem Test byte-identisch.

## Phase-1B-Status

Vorhanden:

- dokumentierte Quellen, Grenzen, Transformations- und Konfliktregeln,
- typisierte Zustands-, Bericht-, V1-Manifest- und V2-Snapshot-Modelle,
- nur lesender ZIP-Reader für Schema 3–6 mit Eintrags- und Gesamtlimits,
- Schutz gegen unerwartete Einträge, Path Traversal, doppelte Pfade und CRC-Abweichungen,
- Transformation aller Inventartypen, Bibliothekswerte, Beziehungen und Provenienzfelder,
- ImageIO-Dekodierung aller Fotos und Normalisierung des tatsächlichen MIME-Typs,
- nativer Dateidialog mit Fortschritt, Bestandszahlen und Validierungshinweisen,
- synthetische Sicherheitsfixtures sowie erfolgreicher Integrationstest mit dem privaten V1.3.2-Export.
- produktives SQLite-Repository mit Transaktion und Integritätsprüfung,
- explizite Bestätigung vor der persistierenden Übernahme,
- Quellkopie und erneute Hash-/Inhaltsprüfung im Staging,
- CRC-verifizierte Fotoablage und Rückleseprüfung des SQLite-Snapshots,
- Backup/Aktivierung/Rollback für den vollständigen `Current`-Ordner,
- lokaler, archivierter JSON-Abschlussbericht,
- Fehlerinjektionstest für die Wiederherstellung nach bereits verschobenem Altbestand,
- vollständiger Commit-Test des privaten Exports in einem isolierten V2-Ziel.
- Legacy-JSON-Reader mit kanonischem Foto-Staging und vollständigem Commit-Test.
- direkter SQLite-Reader mit manueller Ordnerauswahl, read-only Backup-API-Snapshot und anschließend gemeinsamem Validierungs-/Commitpfad.
- automatische Discovery bekannter App-Support-Pfade mit Schemaerkennung ausschließlich an einer V2-eigenen Dateikopie.
- Prozesssperre für direkte Prüfung und Commit, solange die V1-Bundle-ID läuft.
- synthetische WAL-Integrationstests für Wiederholbarkeit, vollständige WAL-Übernahme, unveränderte DB-/WAL-/SHM-/Fotodateien, vollständigen Commit, Prozesssperre und Sperre nach Quelländerung.

Ergebnis des privaten Dry-Runs:

- 54 Boards, 73 Keycap-Sets, 61 Artisans, 55 Switch-Sets, 301 Fotos,
- 53 normalisierte Switch-Installationen,
- keine blockierenden Fehler,
- 15 als JPEG deklarierte HEIC-Bilddateien werden als HEIC normalisiert,
- vier einseitige Switch-Installationen werden kanonisch übernommen,
- drei vorhandene V1-Importhinweise bleiben erhalten.

Noch nicht vorhanden:

- UI-Automation des System-Dateidialogs; Service-, Persistenz- und Rollbackpfade sind als Integrationstests abgedeckt. Die automatische Suche selbst besitzt einen isolierten nativen UI-Test ohne Zugriff auf echte Nutzerdaten.

Der Fotoimport aus nativen Editoren ist seit Phase 2 implementiert; Phase 3 ergänzt den vollständig regenerierbaren Thumbnail-Cache. Phase 1B legte den sicheren Schema-6-Pfad an. Phase 4 erweitert ihn auf ZIP-Schema 3–5, Legacy-JSON, den kontrollierten kompatiblen ZIP-Export und rein lesende PDF-/XLSX-Bestandsberichte. Die ersten fachlichen Restparitätsblöcke binden die direkte V1-SQLite-Quelle und ihre automatische, prozessgesicherte Discovery mit eigenen WAL-Fixtures und denselben Sicherheitsgarantien an.

V1-`coverUrl`- und `externalImageUrls`-Werte bleiben nach der Migration zunächst reine Metadaten. V2 ruft sie weder in Galerie noch Spotlight automatisch auf. Erst im Editor zeigt eine Bestätigung die betroffenen Hosts an und erlaubt die einmalige lokale Übernahme. Der Download verwendet eine ephemere Sitzung ohne Cookies oder persistenten Cache, akzeptiert nur HTTPS einschließlich aller Weiterleitungen, verlangt eine erfolgreiche Bildantwort, erzwingt das 30-MiB-Einzellimit und durchläuft anschließend dieselbe ImageIO-Typprüfung und Skalierung wie ein manuell gewähltes Foto. Bis zum Speichern existieren die Ergebnisse nur als vorbereitete Fotos; Abbruch oder Verwerfen ändert weder Metadaten noch den persistenten Bestand. Beim bestätigten Speichern ersetzen die lokalen Fotos die externen Bildadressen des Eintrags.
