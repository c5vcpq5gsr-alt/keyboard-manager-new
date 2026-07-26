# Datenschutz

Keyboard Manager speichert die Sammlung, Fotos, Sicherungen und Migrationsberichte lokal im eigenen Application-Support-Verzeichnis. Die App schreibt weder in die V1-Datenbank noch in V1-Fotoordner.

Eine Netzwerkverbindung erfolgt nur nach einer ausdrücklichen Aktion:

- Beim bestätigten Übernehmen externer, bereits importierter Bildadressen ruft die App ausschließlich die im Dialog genannten HTTPS-Hosts ab. Cookies und persistenter Netzwerkcache werden dafür nicht verwendet.
- Beim Öffnen eines vom Nutzer ausgewählten HTTPS-Links übergibt die App die Adresse an den Standardbrowser.

Es gibt keine Telemetrie, kein Nutzerkonto und aktuell keine automatische Update-Prüfung. Eine spätere Update-Funktion wird vor ihrer Einführung separat dokumentiert.
