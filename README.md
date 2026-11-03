# 🥐 Klassenlisten 8T

Einfaches Listen-Tool für die Klasse (z. B. **Klassenfrühstück**, Ausflug, Mitbringliste).
Reines Node.js – **kein Next.js, kein Framework, keine Abhängigkeiten**.

## Funktionen
- **Zwei Passwörter / Rollen**
  - Schüler*innen: `Klasse8T` → Einträge hinzufügen, abhaken, **eigene** Einträge löschen
  - Admins: `Klasse8TAdmin` → zusätzlich Listen **erstellen** und **löschen**, alle Einträge löschen
- Listen mit Titel, Datum, Notiz und Fortschrittsbalken
- Einträge: *Was?* + *Wer bringt's mit?* (Name wird im Browser gemerkt)
- Konfetti, wenn eine Liste komplett erledigt ist 🎉
- Daten werden in `data.json` gespeichert
- Aktualisiert sich alle 15 Sekunden automatisch

## Starten
```bash
node server.js
# oder
npm start
```
Dann http://localhost:3000 öffnen.

## Einstellungen (optional, per Umgebungsvariable)
| Variable    | Standard     | Bedeutung                     |
|-------------|--------------|-------------------------------|
| `PORT`      | `3000`       | Port                          |
| `PASSWORD`  | `Klasse8T`   | Passwort für Schüler*innen    |
| `ADMIN_PASSWORD` | `Klasse8TAdmin` | Passwort für Admins     |
| `DATA_FILE` | `./data.json`| Speicherort der Daten         |
| `SECRET`    | (abgeleitet) | Schlüssel für Login-Cookies   |

Läuft überall, wo Node.js ≥ 18 läuft (z. B. Render, Railway, Raspberry Pi, eigener Server).
Hinweis: Auf Hostern ohne dauerhaften Speicher gehen die Daten bei einem Neustart verloren.
