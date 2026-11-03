# 🥐 Klassenlisten 8T

Einfaches Listen-Tool für die Klasse (z. B. **Klassenfrühstück**, Ausflug, Mitbringliste).
Reines Node.js – **kein Next.js, kein Framework, keine Abhängigkeiten**.

## Funktionen
- Login mit Passwort (Standard: `Klasse8T`)
- Mehrere Listen anlegen (Titel, Datum, Notiz)
- Einträge hinzufügen: *Was?* + *Wer bringt's mit?*
- Abhaken, löschen
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
| `PASSWORD`  | `Klasse8T`   | Login-Passwort                |
| `DATA_FILE` | `./data.json`| Speicherort der Daten         |
| `SECRET`    | (abgeleitet) | Schlüssel für Login-Cookies   |

Läuft überall, wo Node.js ≥ 18 läuft (z. B. Render, Railway, Raspberry Pi, eigener Server).
Hinweis: Auf Hostern ohne dauerhaften Speicher gehen die Daten bei einem Neustart verloren.
