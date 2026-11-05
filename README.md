# 🥐 WerMachtWas

Einfaches Listen-Tool für Klassen (z. B. **Klassenfrühstück**, Ausflug, Mitbringliste).
Eine `index.html` auf **GitHub Pages** + **Supabase** als Datenbank. Kein Next.js, kein Framework, kein Build.

## Server
Jede Klasse/Gruppe hat einen eigenen **Server** mit eigenem Link und eigenen Passwörtern:

| Link | Was |
|------|-----|
| `…/WerMachtWas/` | Haupt-Server (Klasse 8T) |
| `…/WerMachtWas/klasse7b` | weitere Server, z. B. Klasse 7B |
| `…/WerMachtWas/admin` | Verwaltung: Server anlegen, umbenennen, löschen, Passwörter vergeben |

Die Verwaltung nutzt ein eigenes **Haupt-Admin-Passwort** (anfangs gleich dem Admin-Passwort des
Haupt-Servers – auf der Admin-Seite unten ändern!).

## Rollen pro Server
- **Schüler*innen**: Einträge hinzufügen, **eigene** Einträge abhaken und löschen
- **Admins**: zusätzlich Listen erstellen, **bearbeiten** (Name, Datum, Notiz, Emoji) und löschen, alle Einträge abhaken und löschen
- Nach dem Datum bleibt eine Liste noch 5 Tage stehen, danach sehen sie nur noch Admins
- Papierkorb: Nach dem Löschen kurz „Rückgängig“, Admins können Gelöschtes 7 Tage lang wiederherstellen
- Geräte sperren: Admins sehen pro Eintrag einen anonymen Gerätecode (gleiche Farbe = gleiches Gerät) und können Geräte sperren
- Ordnung: Einträge werden automatisch in Kategorien sortiert (Admins können korrigieren), Sortieren nach Kategorie/A–Z/Person/Neueste, Suchfeld, Hinweis bei doppelten Einträgen

Passwörter stehen **nicht** im Code – nur als bcrypt-Hash in der Datenbank. Alle Rechte werden in der Datenbank geprüft.

## Einrichtung (neu)
1. Supabase-Projekt anlegen, im **SQL Editor** nacheinander `supabase/setup.sql`, `supabase/update-3-server.sql`, `supabase/update-4-server-emoji.sql`, `supabase/update-5-papierkorb.sql` , `supabase/update-6-geraete-sperren.sql` und `supabase/update-7-kategorien.sql` ausführen.
2. Passwörter des Haupt-Servers und das Haupt-Admin-Passwort setzen:
   ```sql
   update public.servers set
     user_pw_hash  = extensions.crypt('SCHUELER-PASSWORT', extensions.gen_salt('bf')),
     admin_pw_hash = extensions.crypt('ADMIN-PASSWORT',    extensions.gen_salt('bf'))
   where slug = '';
   update public.settings set pw_hash = extensions.crypt('HAUPT-ADMIN-PASSWORT', extensions.gen_salt('bf')) where role = 'super';
   ```
3. In `index.html` `SUPABASE_URL` und `SUPABASE_KEY` (Publishable Key) eintragen.
4. GitHub Pages aktivieren. `404.html` sorgt dafür, dass Links wie `/klasse7b` funktionieren.

## Quellen
Die Wortliste für die automatischen Kategorien (`kategorien.js`) stammt aus den
[Open Food Facts](https://world.openfoodfacts.org)-Taxonomien
([openfoodfacts-server](https://github.com/openfoodfacts/openfoodfacts-server), `taxonomies/food/categories.txt`
und `ingredients.txt`), © Open Food Facts Mitwirkende, Lizenz
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
Die eigene, handgepflegte Stichwortliste in `index.html` hat Vorrang; die Open-Food-Facts-Liste wird genutzt,
wenn sie nichts findet.
