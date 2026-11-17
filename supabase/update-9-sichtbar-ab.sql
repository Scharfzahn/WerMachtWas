-- Update 9: Listen erst ab einem bestimmten Zeitpunkt anzeigen (nach update-8-info-listen.sql ausführen)
-- Vor "show_from" sehen nur Admins die Liste. Leer = sofort sichtbar.

alter table public.lists add column if not exists show_from timestamptz;

-- Darf ein Mitglied diese Liste gerade sehen? (Datum + 5 Tage und "Sichtbar ab")
create or replace function public._member_can_see(p_date text, p_show_from timestamptz)
returns boolean language sql stable as $$
  select coalesce(public._list_day(p_date) + 5 >= public._today(), true)
     and (p_show_from is null or p_show_from <= now());
$$;
revoke all on function public._member_can_see(text, timestamptz) from public, anon, authenticated;

create or replace function public.get_lists(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); adm boolean := s.role = 'admin';
begin
  return coalesce((
    select json_agg(json_build_object(
      'id', l.id, 'title', l.title, 'date', l.date, 'note', l.note, 'emoji', l.emoji, 'kind', l.kind,
      'show_from', l.show_from,
      'scheduled', coalesce(l.show_from > now(), false),
      'expired', coalesce(public._list_day(l.date) < public._today(), false),
      'hidden', coalesce(public._list_day(l.date) + 5 < public._today(), false),
      'items', coalesce((select json_agg(json_build_object(
          'id', i.id, 'what', i.what, 'who', i.who, 'done', i.done, 'category', i.category,
          'created_at', i.created_at,
          'mine', i.owner = s.uid,
          'device', case when adm then public._device_tag(s.server_id, i.owner) end,
          'blocked', case when adm then public._is_blocked(s.server_id, i.owner) end
        ) order by i.created_at)
        from public.items i where i.list_id = l.id and i.deleted_at is null), '[]'::json)
    ) order by l.created_at desc)
    from public.lists l
    where l.server_id = s.server_id and l.deleted_at is null
      and (adm or public._member_can_see(l.date, l.show_from))
  ), '[]'::json);
end $$;

create or replace function public.add_item(p_token text, p_list_id uuid, p_what text, p_who text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); i public.items; k text;
begin
  if s.role <> 'admin' and public._is_blocked(s.server_id, s.uid) then
    raise exception 'Dieses Gerät wurde von einem Admin gesperrt';
  end if;
  if coalesce(trim(p_what), '') = '' then raise exception 'Eintrag fehlt'; end if;
  select kind into k from public.lists
   where id = p_list_id and server_id = s.server_id and deleted_at is null
     and (s.role = 'admin' or public._member_can_see(date, show_from));
  if k is null then raise exception 'Liste nicht gefunden'; end if;
  if k = 'info' and s.role <> 'admin' then raise exception 'In diese Liste können nur Admins etwas eintragen'; end if;
  if (select count(*) from public.items where list_id = p_list_id and deleted_at is null) >= 300 then raise exception 'Liste ist voll'; end if;
  insert into public.items(list_id, what, who, owner)
    values (p_list_id, left(trim(p_what), case when k = 'info' then 500 else 150 end),
            left(trim(coalesce(p_who, '')), 60), s.uid)
    returning * into i;
  return json_build_object('id', i.id, 'what', i.what, 'who', i.who, 'done', i.done, 'category', i.category,
    'created_at', i.created_at, 'mine', true,
    'device', case when s.role = 'admin' then public._device_tag(s.server_id, s.uid) end, 'blocked', false);
end $$;

-- Abhaken/Löschen in noch nicht sichtbaren Listen nur für Admins
create or replace function public.set_item_done(p_token text, p_id uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if not exists (select 1 from public.items i join public.lists l on l.id = i.list_id
                 where i.id = p_id and i.deleted_at is null and l.server_id = s.server_id
                   and (s.role = 'admin' or (i.owner = s.uid and (l.show_from is null or l.show_from <= now())))) then
    raise exception 'Nur eigene Einträge abhaken';
  end if;
  update public.items set done = p_done where id = p_id;
end $$;

-- "Sichtbar ab" setzen oder entfernen (null = sofort sichtbar). Nur Admins.
create or replace function public.set_list_schedule(p_token text, p_id uuid, p_show_from timestamptz default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  update public.lists set show_from = p_show_from where id = p_id and server_id = s.server_id and deleted_at is null;
  if not found then raise exception 'Liste nicht gefunden'; end if;
end $$;

revoke all on function public.set_list_schedule(text, uuid, timestamptz) from public, authenticated;
grant execute on function public.set_list_schedule(text, uuid, timestamptz) to anon;

notify pgrst, 'reload schema';
