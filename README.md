# Kies Drive

Eigenständige iOS-/macOS-Navigations-App mit persistentem Trip-Lock und einem
eigenen TrueNAS-Dienst für Live-Daten und MCP. Kies Drive bleibt bei Ausfällen
des Servers vollständig navigationsfähig. Die normale Kies-App liefert nur
optionale Dienste wie Jarvis, Tankpreise und verifizierte Mautinformationen.

## Dienste

- App: MapKit-Navigation, Pflichtpunkte, Pausen, Mautvergleich, Route-Lock
- TrueNAS: `ghcr.io/tim-stubbe/kies-drive:latest`, Port `18080`
- MCP: `https://<truenas>:18080/mcp`
- Kies-Anbindung: `KIES_BASE_URL` und ein widerrufbarer Kies-Gerätetoken

Secrets werden ausschließlich in TrueNAS als Umgebungsvariablen gesetzt.
