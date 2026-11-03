-- WerMachtWas – Datenbank-Setup für Supabase
-- Einmal im Supabase SQL-Editor ausführen. Passwörter werden danach separat gesetzt
-- (siehe README) und stehen NICHT im Code.

create extension if not exists pgcrypto with schema extensions;

create table public.settings (
  role text primary key check (role in ('admin','user')),
  pw_hash text not null
);
create table public.sessions (
  token text primary key,
  role text not null,
  uid text not null,
  expires_at timestamptz not null
);
create table public.lists (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  date text not null default '',
  note text not null default '',
  emoji text not null default '',
  created_at timestamptz not null default now()
);
create table public.items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists(id) on delete cascade,
  what text not null,
  who text not null default '',
  done boolean not null default false,
  owner text not null,
  created_at timestamptz not null default now()
);
create index items_list_id_idx on public.items(list_id);

-- Kein direkter Zugriff auf Tabellen – nur über die Funktionen unten
alter table public.settings enable row level security;
alter table public.sessions enable row level security;
alter table public.lists enable row level security;
alter table public.items enable row level security;
revoke all on public.settings, public.sessions, public.lists, public.items from anon, authenticated;

create or replace function public._session(p_token text)
returns public.sessions language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions;
begin
  select * into s from public.sessions where token = p_token and expires_at > now();
  if not found then raise exception 'Nicht eingeloggt' using errcode = '28000'; end if;
  return s;
end $$;
revoke all on function public._session(text) from public, anon, authenticated;

create or replace function public.login(p_password text, p_uid text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r text; t text; u text;
begin
  select role into r from public.settings
   where pw_hash = extensions.crypt(p_password, pw_hash)
   order by (role = 'admin') desc limit 1;
  if r is null then perform pg_sleep(0.7); raise exception 'Falsches Passwort' using errcode = '28P01'; end if;
  t := encode(extensions.gen_random_bytes(32), 'hex');
  u := coalesce(nullif(left(p_uid, 40), ''), encode(extensions.gen_random_bytes(8), 'hex'));
  delete from public.sessions where expires_at < now();
  insert into public.sessions values (t, r, u, now() + interval '30 days');
  return json_build_object('token', t, 'role', r, 'uid', u);
end $$;

create or replace function public.logout(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.sessions where token = p_token;
$$;

create or replace function public.me(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin return json_build_object('role', s.role, 'uid', s.uid); end $$;

create or replace function public.delete_list(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  delete from public.lists where id = p_id;
end $$;

create or replace function public.set_item_done(p_token text, p_id uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' and not exists (select 1 from public.items where id = p_id and owner = s.uid) then
    raise exception 'Nur eigene Einträge abhaken';
  end if;
  update public.items set done = p_done where id = p_id;
end $$;

create or replace function public.delete_item(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' and not exists (select 1 from public.items where id = p_id and owner = s.uid) then
    raise exception 'Nur eigene Einträge löschen';
  end if;
  delete from public.items where id = p_id;
end $$;

revoke all on function public.login(text, text), public.logout(text), public.me(text), public.get_lists(text),
  public.delete_list(text, uuid), public.add_item(text, uuid, text, text),
  public.set_item_done(text, uuid, boolean), public.delete_item(text, uuid) from public;
grant execute on function public.login(text, text), public.logout(text), public.me(text), public.get_lists(text),
  public.delete_list(text, uuid), public.add_item(text, uuid, text, text),
  public.set_item_done(text, uuid, boolean), public.delete_item(text, uuid) to anon;

-- Listen bearbeiten, Emoji, Ablauf
create or replace function public._list_day(p_date text)
returns date language sql immutable as $$
  select case when p_date ~ '^\d{4}-\d{2}-\d{2}$' then p_date::date end;
$$;
revoke all on function public._list_day(text) from public, anon, authenticated;

create or replace function public._today()
returns date language sql stable as $$ select (now() at time zone 'Europe/Berlin')::date; $$;
revoke all on function public._today() from public, anon, authenticated;

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
    where s.role = 'admin' or coalesce(public._list_day(l.date) + 5 >= public._today(), true)
  ), '[]'::json);
end $$;

create or replace function public.create_list(p_token text, p_title text, p_date text default '', p_note text default '', p_emoji text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); l public.lists;
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Titel fehlt'; end if;
  insert into public.lists(title, date, note, emoji)
    values (left(trim(p_title), 100), left(coalesce(p_date, ''), 20), left(trim(coalesce(p_note, '')), 500), left(coalesce(p_emoji, ''), 16))
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
  where id = p_id;
  if not found then raise exception 'Liste nicht gefunden'; end if;
end $$;

-- Schüler*innen dürfen in ausgeblendeten Listen nichts mehr eintragen
create or replace function public.add_item(p_token text, p_list_id uuid, p_what text, p_who text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); i public.items;
begin
  if coalesce(trim(p_what), '') = '' then raise exception 'Eintrag fehlt'; end if;
  if not exists (select 1 from public.lists where id = p_list_id
                 and (s.role = 'admin' or coalesce(public._list_day(date) + 5 >= public._today(), true))) then
    raise exception 'Liste nicht gefunden';
  end if;
  if (select count(*) from public.items where list_id = p_list_id) >= 300 then raise exception 'Liste ist voll'; end if;
  insert into public.items(list_id, what, who, owner)
    values (p_list_id, left(trim(p_what), 150), left(trim(coalesce(p_who, '')), 60), s.uid)
    returning * into i;
  return json_build_object('id', i.id, 'what', i.what, 'who', i.who, 'done', i.done, 'owner', i.owner);
end $$;

revoke all on function public.create_list(text, text, text, text, text), public.update_list(text, uuid, text, text, text, text) from public;
grant execute on function public.create_list(text, text, text, text, text), public.update_list(text, uuid, text, text, text, text) to anon;
