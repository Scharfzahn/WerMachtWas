-- Update 2: Listen bearbeiten, Emoji, Ablauf nach Datum + 5 Tagen
-- Einmal im Supabase SQL-Editor ausführen (bei Neuinstallation nicht nötig, steckt schon in setup.sql)

alter table public.lists add column if not exists emoji text not null default '';

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

drop function if exists public.create_list(text, text, text, text);
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
