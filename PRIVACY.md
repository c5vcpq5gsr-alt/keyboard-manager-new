# Datenschutz

Keyboard Manager speichert die Sammlung, Fotos, Sicherungen und Migrationsberichte lokal im eigenen Application-Support-Verzeichnis. Die App schreibt weder in die V1-Datenbank noch in V1-Fotoordner.

Eine Netzwerkverbindung erfolgt ausschließlich für sichtbare Funktionen:

- Beim bestätigten Übernehmen externer, bereits importierter Bildadressen ruft die App ausschließlich die im Dialog genannten HTTPS-Hosts ab. Cookies und persistenter Netzwerkcache werden dafür nicht verwendet.
- Beim Öffnen eines vom Nutzer ausgewählten HTTPS-Links übergibt die App die Adresse an den Standardbrowser.
- Beim Start fragt die App den öffentlichen GitHub-Endpunkt des Keyboard-Manager-Repositories nach dem neuesten stabilen Release ab. Dabei werden nur die installierte Versionsnummer und keine Sammlungs-, Geräte- oder Nutzerdaten übertragen. Die Prüfung hat ein kurzes Zeitlimit und eine nicht erreichbare Updatequelle beeinträchtigt die restliche App nicht.
- Erst nach dem ausdrücklichen Klick auf „Jetzt laden“ lädt die App das veröffentlichte DMG sowie dessen SHA-256-Datei. Das DMG wird nur geöffnet, wenn seine lokale Prüfsumme exakt mit der veröffentlichten Prüfsumme übereinstimmt. Der geprüfte Installer wird im Ordner `Downloads/Keyboard Manager Updates` abgelegt.

Es gibt keine Telemetrie und kein Nutzerkonto.
