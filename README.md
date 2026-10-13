# Kies Drive

Eigenständige iOS-/macOS-Navigations-App mit persistentem Trip-Lock und einem
eigenen TrueNAS-Dienst für Live-Daten und MCP. Kies Drive bleibt bei Ausfällen
des Servers vollständig navigationsfähig. Der eigenständige Dienst recherchiert
Mautinformationen über das konfigurierte SearXNG. Die normale Kies-App liefert
nur noch optionale Zusatzdienste wie Jarvis und Tankpreise.

## Dienste

- App: MapKit-Navigation, Pflichtpunkte, Pausen, Mautvergleich, Route-Lock
- TrueNAS: `ghcr.io/tim-stubbe/kies-drive:latest`, Port `18080`
- MCP: `https://<truenas>:18080/mcp`

## CarPlay

Kies Drive contains a native CarPlay navigation scene with its own MapKit map,
vehicle following, route overview, turn guidance, travel estimates, route-lock
restoration and route-stop selection. The entitlement template is stored in
`Sources/KiesDrive/KiesDriveiOS.entitlements`. Enable it as the target's Code
Signing Entitlements after Apple has granted the team the CarPlay navigation
capability; keeping it detached lets ordinary development builds continue to
install before that approval.
- Öffentliche Konten: Registrierung, E-Mail-Bestätigung, Argon2id-Passwortschutz
  und optionale Authenticator-2FA mit einmaligen Wiederherstellungscodes.
  Sitzungen werden in der App automatisch im Apple-Schlüsselbund verwaltet;
  Nutzer müssen keine Geräte-Tokens eingeben.
- E-Mail: `KIES_DRIVE_PUBLIC_URL`, `SMTP_HOST`, `SMTP_FROM` sowie je nach
  Anbieter `SMTP_USERNAME` und `SMTP_PASSWORD` im TrueNAS-App-Formular setzen.
- Mautrecherche: `SEARXNG_URL` auf die interne URL der SearXNG-Instanz setzen.
  Kies Drive übernimmt nur ausdrücklich als Gesamtmaut bezeichnete Beträge aus
  HTTPS-Quellen; andernfalls bleibt der Preis bewusst unbekannt.
- Die optionale Anbindung an den bisherigen Kies-Dienst bleibt ausschließlich
  serverseitig über `KIES_BASE_URL` und das optionale `KIES_DEVICE_TOKEN`
  gekapselt. Ohne dieses Legacy-Token starten Konto, MCP und Mautsuche trotzdem.

Secrets werden ausschließlich in TrueNAS als Umgebungsvariablen gesetzt.
