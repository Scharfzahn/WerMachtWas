-- Update 5: Papierkorb – Gelöschtes bleibt 7 Tage und kann wiederhergestellt werden
-- (nach update-4-server-emoji.sql ausführen)

alter table public.items add column if not exists deleted_at timestamptz;
alter table public.lists add column if not exists deleted_at timestamptz;

-- Endgültig weg nach 7 Tagen
create or replace function public._purge_trash()
returns void language sql security definer set search_path = public as $$
  delete from public.items where deleted_at < now() - interval '7 days';
  delete from public.lists where deleted_at < now() - interval '7 days';
$$;
revoke all on function public._purge_trash() from public, anon, authenticated;

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
        from public.items i where i.list_id = l.id and i.deleted_at is null), '[]'::json)
    ) order by l.created_at desc)
    from public.lists l
    where l.server_id = s.server_id and l.deleted_at is null
      and (s.role = 'admin' or coalesce(public._list_day(l.date) + 5 >= public._today(), true))
  ), '[]'::json);
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
  where id = p_id and server_id = s.server_id and deleted_at is null;
  if not found then raise exception 'Liste nicht gefunden'; end if;
end $$;

create or replace function public.delete_list(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  update public.lists set deleted_at = now() where id = p_id and server_id = s.server_id and deleted_at is null;
  perform public._purge_trash();
end $$;

create or replace function public.add_item(p_token text, p_list_id uuid, p_what text, p_who text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); i public.items;
begin
  if coalesce(trim(p_what), '') = '' then raise exception 'Eintrag fehlt'; end if;
  if not exists (select 1 from public.lists where id = p_list_id and server_id = s.server_id and deleted_at is null
                 and (s.role = 'admin' or coalesce(public._list_day(date) + 5 >= public._today(), true))) then
    raise exception 'Liste nicht gefunden';
  end if;
  if (select count(*) from public.items where list_id = p_list_id and deleted_at is null) >= 300 then raise exception 'Liste ist voll'; end if;
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
                 where i.id = p_id and i.deleted_at is null and l.server_id = s.server_id
                   and (s.role = 'admin' or i.owner = s.uid)) then
    raise exception 'Nur eigene Einträge abhaken';
  end if;
  update public.items set done = p_done where id = p_id;
end $$;

create or replace function public.delete_item(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if not exists (select 1 from public.items i join public.lists l on l.id = i.list_id
                 where i.id = p_id and i.deleted_at is null and l.server_id = s.server_id
                   and (s.role = 'admin' or i.owner = s.uid)) then
    raise exception 'Nur eigene Einträge löschen';
  end if;
  update public.items set deleted_at = now() where id = p_id;
  perform public._purge_trash();
end $$;

-- Wiederherstellen: Admins immer, Schüler*innen nur eigene Einträge (für „Rückgängig“)
create or replace function public.restore_item(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if not exists (select 1 from public.items i join public.lists l on l.id = i.list_id
                 where i.id = p_id and i.deleted_at is not null and l.server_id = s.server_id
                   and (s.role = 'admin' or i.owner = s.uid)) then
    raise exception 'Eintrag nicht im Papierkorb';
  end if;
  update public.items set deleted_at = null where id = p_id;
end $$;

create or replace function public.restore_list(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  update public.lists set deleted_at = null where id = p_id and server_id = s.server_id and deleted_at is not null;
  if not found then raise exception 'Liste nicht im Papierkorb'; end if;
end $$;

-- Papierkorb-Inhalt (nur Admins)
create or replace function public.get_trash(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  perform public._purge_trash();
  return json_build_object(
    'lists', coalesce((select json_agg(json_build_object(
        'id', l.id, 'title', l.title, 'emoji', l.emoji, 'deleted_at', l.deleted_at,
        'count', (select count(*) from public.items i where i.list_id = l.id and i.deleted_at is null))
        order by l.deleted_at desc)
      from public.lists l where l.server_id = s.server_id and l.deleted_at is not null), '[]'::json),
    'items', coalesce((select json_agg(json_build_object(
        'id', i.id, 'what', i.what, 'who', i.who, 'deleted_at', i.deleted_at,
        'list', l.title, 'list_deleted', l.deleted_at is not null)
        order by i.deleted_at desc)
      from public.items i join public.lists l on l.id = i.list_id
      where l.server_id = s.server_id and i.deleted_at is not null), '[]'::json)
  );
end $$;

-- Zähler auf der Admin-Startseite ohne Gelöschtes
create or replace function public.super_servers(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token);
begin
  return coalesce((select json_agg(json_build_object(
      'id', v.id, 'slug', v.slug, 'name', v.name, 'emoji', v.emoji, 'created_at', v.created_at,
      'lists', (select count(*) from public.lists l where l.server_id = v.id and l.deleted_at is null),
      'items', (select count(*) from public.items i join public.lists l on l.id = i.list_id
                where l.server_id = v.id and l.deleted_at is null and i.deleted_at is null)
    ) order by (v.slug = '') desc, v.created_at) from public.servers v), '[]'::json);
end $$;

revoke all on function public.restore_item(text, uuid), public.restore_list(text, uuid), public.get_trash(text) from public, authenticated;
grant execute on function public.restore_item(text, uuid), public.restore_list(text, uuid), public.get_trash(text) to anon;

notify pgrst, 'reload schema';
