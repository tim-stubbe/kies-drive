# Kies Drive

Eigenständige iOS-/macOS-Navigations-App mit persistentem Trip-Lock und einem
eigenen TrueNAS-Dienst für Live-Daten und MCP. Kies Drive bleibt bei Ausfällen
des Servers vollständig navigationsfähig. Der eigenständige Dienst recherchiert
Mautinformationen über das konfigurierte SearXNG. Die normale Kies-App liefert
nur noch optionale Zusatzdienste wie Jarvis und Tankpreise.

## Dienste

- App: MapKit-Navigation, Pflichtpunkte, Pausen, Mautvergleich, Route-Lock
- TrueNAS: `ghcr.io/tim-stubbe/kies-drive:latest`, Port `18080`
- MCP: `https://truenas-scale.tail8d3a5d.ts.net:10000/kies-drive/mcp`; ChatGPT entdeckt dort
  automatisch die Browser-Anmeldung mit OAuth 2.1/PKCE. Es muss kein Token
  kopiert oder im Container hinterlegt werden.

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
  Nutzer müssen keine Geräte-Tokens eingeben. Der Bestätigungslink kehrt über
  `kiesdrive://auth-complete` direkt in den geöffneten Registrierungsablauf
  zurück und meldet das bestätigte Konto an. Beim Aktivieren von 2FA werden
  ältere Sitzungen automatisch widerrufen. Direkt nach der ersten Bestätigung
  bietet die App die Einrichtung per Authenticator verständlich an; sie kann
  auch bewusst auf später verschoben werden.
- E-Mail: `KIES_DRIVE_PUBLIC_URL`, `SMTP_HOST`, `SMTP_FROM` sowie je nach
  Anbieter `SMTP_USERNAME` und `SMTP_PASSWORD` im TrueNAS-App-Formular setzen.
  `KIES_DRIVE_PUBLIC_URL` muss die öffentliche HTTPS-Adresse des gesamten
  Dienstes sein, damit Konto-Bestätigung und MCP-OAuth dieselbe Domain nutzen.
  Für einen öffentlichen App-Build wird dieselbe Adresse als Xcode-Buildwert
  `KIES_DRIVE_SERVER_URL=https://…` gesetzt. Die App übernimmt sie automatisch;
  Nutzer sehen weder Serveradresse noch Zugangstoken.
  Über `/readyz` lässt sich ohne Ausgabe von Zugangsdaten prüfen, ob öffentliche
  HTTPS-Adresse und E-Mail-Versand für neue Registrierungen eingerichtet sind.
  Erst wenn dort `ok: true` zurückkommt, ist der Account-Einstieg produktionsbereit.
- Mautrecherche: `SEARXNG_URL` auf die interne URL der SearXNG-Instanz setzen.
  Kies Drive übernimmt nur ausdrücklich als Gesamtmaut bezeichnete Beträge aus
  HTTPS-Quellen; andernfalls bleibt der Preis bewusst unbekannt.
- Die optionale Anbindung an den bisherigen Kies-Dienst bleibt ausschließlich
  serverseitig über `KIES_BASE_URL` und das optionale `KIES_DEVICE_TOKEN`
  gekapselt. Ohne dieses Legacy-Token starten Konto, MCP und Mautsuche trotzdem.
  TLS wird dabei standardmäßig geprüft (`KIES_VERIFY_TLS=true`).

Secrets werden ausschließlich in TrueNAS als Umgebungsvariablen gesetzt.
