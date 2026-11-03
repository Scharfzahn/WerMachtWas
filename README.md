# 🥐 WerMachtWas – Klassenlisten

Einfaches Listen-Tool für die Klasse (z. B. **Klassenfrühstück**, Ausflug, Mitbringliste).
Eine einzige `index.html` (läuft auf **GitHub Pages**) + **Supabase** als Datenbank.
Kein Next.js, kein Framework, kein Build.

## Funktionen
- Zwei Rollen mit eigenem Passwort
  - **Schüler*innen**: Einträge hinzufügen, **eigene** Einträge abhaken und löschen
  - **Admins**: zusätzlich Listen erstellen, **bearbeiten** (Name, Datum, Notiz, Emoji) und löschen, alle Einträge abhaken und löschen
- Listen mit Titel, Datum, Notiz, Emoji und Fortschrittsbalken
- Nach dem Datum bleibt eine Liste noch 5 Tage stehen, danach sehen sie nur noch Admins
- Aktualisiert sich alle 15 Sekunden, Konfetti wenn alles erledigt ist 🎉

Die Passwörter stehen **nicht** im Code – sie liegen nur verschlüsselt (bcrypt) in der Datenbank.
Alle Rechte werden in der Datenbank geprüft, nicht im Browser.

## Einrichtung
1. Supabase-Projekt anlegen, im **SQL Editor** den Inhalt von `supabase/setup.sql` ausführen.
2. Passwörter setzen (eigene Passwörter einsetzen):
   ```sql
   insert into public.settings(role, pw_hash) values
     ('user',  extensions.crypt('SCHUELER-PASSWORT', extensions.gen_salt('bf'))),
     ('admin', extensions.crypt('ADMIN-PASSWORT',    extensions.gen_salt('bf')))
   on conflict (role) do update set pw_hash = excluded.pw_hash;
   ```
   Derselbe Befehl ändert die Passwörter später. Alle abmelden: `delete from public.sessions;`
3. In `index.html` `SUPABASE_URL` und `SUPABASE_KEY` (Publishable Key) eintragen.
4. GitHub Pages für das Repo aktivieren – fertig.
