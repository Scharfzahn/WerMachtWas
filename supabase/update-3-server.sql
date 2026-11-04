-- Update 3: Mehrere Server (z. B. /klasse8t) + Admin-Startseite
-- Enthält auch Update 2 (Bearbeiten, Emoji, Ablauf) – Update 2 muss also NICHT extra laufen.
-- Einmal komplett im Supabase SQL-Editor ausführen. Kann gefahrlos mehrmals laufen.
-- Bestehende Listen + Passwörter wandern auf den Haupt-Server (normaler Link ohne /...).

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabellen ----------
alter table public.lists add column if not exists emoji text not null default '';

create table if not exists public.servers (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  user_pw_hash text not null,
  admin_pw_hash text not null,
  created_at timestamptz not null default now()
);
alter table public.servers enable row level security;
revoke all on public.servers from anon, authenticated;

-- Haupt-Server (slug '') mit den bisherigen Passwörtern
insert into public.servers(slug, name, user_pw_hash, admin_pw_hash)
select '', 'Klasse 8T',
  coalesce((select pw_hash from public.settings where role = 'user'),  extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf'))),
  coalesce((select pw_hash from public.settings where role = 'admin'), extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')))
where not exists (select 1 from public.servers where slug = '');

-- Haupt-Admin-Passwort für die Startseite /admin (anfangs = bisheriges Admin-Passwort)
alter table public.settings drop constraint if exists settings_role_check;
alter table public.settings add constraint settings_role_check check (role in ('admin', 'user', 'super'));
insert into public.settings(role, pw_hash)
select 'super', pw_hash from public.settings where role = 'admin'
on conflict (role) do nothing;

alter table public.lists add column if not exists server_id uuid references public.servers(id) on delete cascade;
update public.lists set server_id = (select id from public.servers where slug = '') where server_id is null;
alter table public.lists alter column server_id set not null;
create index if not exists lists_server_id_idx on public.lists(server_id);

alter table public.sessions add column if not exists server_id uuid references public.servers(id) on delete cascade;
update public.sessions set server_id = (select id from public.servers where slug = '') where server_id is null and role <> 'super';

-- ---------- Hilfsfunktionen ----------
create or replace function public._list_day(p_date text)
returns date language sql immutable as $$
  select case when p_date ~ '^\d{4}-\d{2}-\d{2}$' then p_date::date end;
$$;
create or replace function public._today()
returns date language sql stable as $$ select (now() at time zone 'Europe/Berlin')::date; $$;

-- Sitzung eines Servers (keine Haupt-Admin-Sitzung)
create or replace function public._session(p_token text)
returns public.sessions language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions;
begin
  select * into s from public.sessions
   where token = p_token and expires_at > now() and role <> 'super' and server_id is not null;
  if not found then raise exception 'Nicht eingeloggt' using errcode = '28000'; end if;
  return s;
end $$;

-- Haupt-Admin-Sitzung
create or replace function public._super(p_token text)
returns public.sessions language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions;
begin
  select * into s from public.sessions where token = p_token and expires_at > now() and role = 'super';
  if not found then raise exception 'Nicht eingeloggt' using errcode = '28000'; end if;
  return s;
end $$;

create or replace function public._norm_slug(p text)
returns text language sql immutable as $$ select lower(trim(coalesce(p, ''))); $$;

revoke all on function public._list_day(text), public._today(), public._session(text), public._super(text), public._norm_slug(text)
  from public, anon, authenticated;

-- ---------- Öffentlich ----------
create or replace function public.server_info(p_server text default '')
returns json language sql security definer set search_path = public, extensions as $$
  select json_build_object('name', name, 'slug', slug) from public.servers where slug = public._norm_slug(p_server);
$$;

drop function if exists public.login(text, text);
create or replace function public.login(p_password text, p_uid text default null, p_server text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare sv public.servers; r text; t text; u text;
begin
  select * into sv from public.servers where slug = public._norm_slug(p_server);
  if not found then raise exception 'Server nicht gefunden'; end if;
  if sv.admin_pw_hash = extensions.crypt(p_password, sv.admin_pw_hash) then r := 'admin';
  elsif sv.user_pw_hash = extensions.crypt(p_password, sv.user_pw_hash) then r := 'user';
  else perform pg_sleep(0.7); raise exception 'Falsches Passwort' using errcode = '28P01';
  end if;
  t := encode(extensions.gen_random_bytes(32), 'hex');
  u := coalesce(nullif(left(p_uid, 40), ''), encode(extensions.gen_random_bytes(8), 'hex'));
  delete from public.sessions where expires_at < now();
  insert into public.sessions(token, role, uid, expires_at, server_id) values (t, r, u, now() + interval '30 days', sv.id);
  return json_build_object('token', t, 'role', r, 'uid', u);
end $$;

create or replace function public.me(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  return json_build_object('role', s.role, 'uid', s.uid,
    'server', (select name from public.servers where id = s.server_id));
end $$;

-- ---------- Listen (immer nur im eigenen Server) ----------
create or replace function public.get_lists(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'id', l.id, 'title', l.title, 'date', l.date, 'note', l.note, 'emoji', l.emoji,
      'expired', coalesce(public._list_day(l.date) < public._today(), false),
      'hidden', coalesce(public._list_day(l.date) + 5 < public._today(), false),
      'items', coalesce((select json_agg(json_build_object(
          'id', i.id, 'what', i.what, 'who', i.who, 'done', i.done, 'owner', i.owner) order by i.created_at)
        from public.items i where i.list_id = l.id), '[]'::json)
    ) order by l.created_at desc)
    from public.lists l
    where l.server_id = s.server_id
      and (s.role = 'admin' or coalesce(public._list_day(l.date) + 5 >= public._today(), true))
  ), '[]'::json);
end $$;

drop function if exists public.create_list(text, text, text, text);
create or replace function public.create_list(p_token text, p_title text, p_date text default '', p_note text default '', p_emoji text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); l public.lists;
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Titel fehlt'; end if;
  if (select count(*) from public.lists where server_id = s.server_id) >= 200 then raise exception 'Zu viele Listen'; end if;
  insert into public.lists(title, date, note, emoji, server_id)
    values (left(trim(p_title), 100), left(coalesce(p_date, ''), 20), left(trim(coalesce(p_note, '')), 500),
            left(coalesce(p_emoji, ''), 16), s.server_id)
    returning * into l;
  return json_build_object('id', l.id);
end $$;

create or replace function public.update_list(p_token text, p_id uuid, p_title text, p_date text default '', p_note text default '', p_emoji text default '')
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Titel fehlt'; end if;
  update public.lists set
    title = left(trim(p_title), 100),
    date = left(coalesce(p_date, ''), 20),
    note = left(trim(coalesce(p_note, '')), 500),
    emoji = left(coalesce(p_emoji, ''), 16)
  where id = p_id and server_id = s.server_id;
  if not found then raise exception 'Liste nicht gefunden'; end if;
end $$;

create or replace function public.delete_list(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  delete from public.lists where id = p_id and server_id = s.server_id;
end $$;

create or replace function public.add_item(p_token text, p_list_id uuid, p_what text, p_who text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); i public.items;
begin
  if coalesce(trim(p_what), '') = '' then raise exception 'Eintrag fehlt'; end if;
  if not exists (select 1 from public.lists where id = p_list_id and server_id = s.server_id
                 and (s.role = 'admin' or coalesce(public._list_day(date) + 5 >= public._today(), true))) then
    raise exception 'Liste nicht gefunden';
  end if;
  if (select count(*) from public.items where list_id = p_list_id) >= 300 then raise exception 'Liste ist voll'; end if;
  insert into public.items(list_id, what, who, owner)
    values (p_list_id, left(trim(p_what), 150), left(trim(coalesce(p_who, '')), 60), s.uid)
    returning * into i;
  return json_build_object('id', i.id, 'what', i.what, 'who', i.who, 'done', i.done, 'owner', i.owner);
end $$;

create or replace function public.set_item_done(p_token text, p_id uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if not exists (select 1 from public.items i join public.lists l on l.id = i.list_id
                 where i.id = p_id and l.server_id = s.server_id and (s.role = 'admin' or i.owner = s.uid)) then
    raise exception 'Nur eigene Einträge abhaken';
  end if;
  update public.items set done = p_done where id = p_id;
end $$;

create or replace function public.delete_item(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if not exists (select 1 from public.items i join public.lists l on l.id = i.list_id
                 where i.id = p_id and l.server_id = s.server_id and (s.role = 'admin' or i.owner = s.uid)) then
    raise exception 'Nur eigene Einträge löschen';
  end if;
  delete from public.items where id = p_id;
end $$;

-- ---------- Haupt-Admin (Startseite /admin) ----------
create or replace function public.super_login(p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare t text;
begin
  if not exists (select 1 from public.settings where role = 'super' and pw_hash = extensions.crypt(p_password, pw_hash)) then
    perform pg_sleep(0.7); raise exception 'Falsches Passwort' using errcode = '28P01';
  end if;
  t := encode(extensions.gen_random_bytes(32), 'hex');
  delete from public.sessions where expires_at < now();
  insert into public.sessions(token, role, uid, expires_at) values (t, 'super', 'super', now() + interval '7 days');
  return json_build_object('token', t);
end $$;

create or replace function public.super_servers(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token);
begin
  return coalesce((select json_agg(json_build_object(
      'id', v.id, 'slug', v.slug, 'name', v.name, 'created_at', v.created_at,
      'lists', (select count(*) from public.lists l where l.server_id = v.id),
      'items', (select count(*) from public.items i join public.lists l on l.id = i.list_id where l.server_id = v.id)
    ) order by (v.slug = '') desc, v.created_at) from public.servers v), '[]'::json);
end $$;

-- p_id null = neuen Server anlegen. Leere Passwörter beim Bearbeiten = unverändert.
create or replace function public.super_save_server(p_token text, p_id uuid, p_name text, p_slug text,
  p_user_pw text default '', p_admin_pw text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token); v public.servers; sl text := public._norm_slug(p_slug);
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Name fehlt'; end if;
  if coalesce(p_user_pw, '') <> '' and length(p_user_pw) < 4 then raise exception 'Passwort zu kurz (mind. 4 Zeichen)'; end if;
  if coalesce(p_admin_pw, '') <> '' and length(p_admin_pw) < 4 then raise exception 'Passwort zu kurz (mind. 4 Zeichen)'; end if;
  if coalesce(p_user_pw, '') <> '' and p_user_pw = p_admin_pw then raise exception 'Schüler- und Admin-Passwort müssen verschieden sein'; end if;

  if p_id is not null then
    select * into v from public.servers where id = p_id;
    if not found then raise exception 'Server nicht gefunden'; end if;
  end if;

  -- Link-Name prüfen (Haupt-Server behält immer den normalen Link)
  if p_id is null or v.slug <> '' then
    if sl !~ '^[a-z0-9][a-z0-9-]{1,39}$' then raise exception 'Link nur mit a–z, 0–9 und -, mind. 2 Zeichen'; end if;
    if sl in ('admin', 'index', '404', 'supabase') then raise exception 'Dieser Link ist reserviert'; end if;
    if exists (select 1 from public.servers where slug = sl and id is distinct from p_id) then raise exception 'Link ist schon vergeben'; end if;
  else
    sl := '';
  end if;

  if p_id is null then
    if coalesce(p_user_pw, '') = '' or coalesce(p_admin_pw, '') = '' then raise exception 'Beide Passwörter angeben'; end if;
    if (select count(*) from public.servers) >= 100 then raise exception 'Zu viele Server'; end if;
    insert into public.servers(slug, name, user_pw_hash, admin_pw_hash)
      values (sl, left(trim(p_name), 60), extensions.crypt(p_user_pw, extensions.gen_salt('bf')), extensions.crypt(p_admin_pw, extensions.gen_salt('bf')))
      returning * into v;
  else
    update public.servers set slug = sl, name = left(trim(p_name), 60) where id = p_id;
    if coalesce(p_user_pw, '') <> '' then
      update public.servers set user_pw_hash = extensions.crypt(p_user_pw, extensions.gen_salt('bf')) where id = p_id;
      delete from public.sessions where server_id = p_id and role = 'user';
    end if;
    if coalesce(p_admin_pw, '') <> '' then
      update public.servers set admin_pw_hash = extensions.crypt(p_admin_pw, extensions.gen_salt('bf')) where id = p_id;
      delete from public.sessions where server_id = p_id and role = 'admin';
    end if;
  end if;
  return json_build_object('id', coalesce(v.id, p_id), 'slug', sl);
end $$;

create or replace function public.super_delete_server(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token);
begin
  if exists (select 1 from public.servers where id = p_id and slug = '') then raise exception 'Der Haupt-Server kann nicht gelöscht werden'; end if;
  delete from public.servers where id = p_id;
end $$;

create or replace function public.super_set_password(p_token text, p_new text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token);
begin
  if length(coalesce(p_new, '')) < 6 then raise exception 'Passwort zu kurz (mind. 6 Zeichen)'; end if;
  update public.settings set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where role = 'super';
  delete from public.sessions where role = 'super' and token <> p_token;
end $$;

-- ---------- Rechte ----------
revoke all on function
  public.server_info(text), public.login(text, text, text), public.logout(text), public.me(text), public.get_lists(text),
  public.create_list(text, text, text, text, text), public.update_list(text, uuid, text, text, text, text),
  public.delete_list(text, uuid), public.add_item(text, uuid, text, text), public.set_item_done(text, uuid, boolean),
  public.delete_item(text, uuid), public.super_login(text), public.super_servers(text),
  public.super_save_server(text, uuid, text, text, text, text), public.super_delete_server(text, uuid),
  public.super_set_password(text, text)
from public, authenticated;
grant execute on function
  public.server_info(text), public.login(text, text, text), public.logout(text), public.me(text), public.get_lists(text),
  public.create_list(text, text, text, text, text), public.update_list(text, uuid, text, text, text, text),
  public.delete_list(text, uuid), public.add_item(text, uuid, text, text), public.set_item_done(text, uuid, boolean),
  public.delete_item(text, uuid), public.super_login(text), public.super_servers(text),
  public.super_save_server(text, uuid, text, text, text, text), public.super_delete_server(text, uuid),
  public.super_set_password(text, text)
to anon;

notify pgrst, 'reload schema';
