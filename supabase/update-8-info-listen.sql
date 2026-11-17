-- Update 8: Info-Listen ("Infos & Links") – nur Admins dürfen eintragen
-- (nach update-7-kategorien.sql ausführen)

alter table public.lists add column if not exists kind text not null default 'normal';
alter table public.lists drop constraint if exists lists_kind_check;
alter table public.lists add constraint lists_kind_check check (kind in ('normal', 'info'));

create or replace function public.get_lists(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); adm boolean := s.role = 'admin';
begin
  return coalesce((
    select json_agg(json_build_object(
      'id', l.id, 'title', l.title, 'date', l.date, 'note', l.note, 'emoji', l.emoji, 'kind', l.kind,
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
      and (adm or coalesce(public._list_day(l.date) + 5 >= public._today(), true))
  ), '[]'::json);
end $$;

-- Art einer Liste festlegen (nur Admins). Getrennte Funktion, damit create_list/update_list gleich bleiben.
create or replace function public.set_list_kind(p_token text, p_id uuid, p_kind text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  if coalesce(p_kind, '') not in ('normal', 'info') then raise exception 'Unbekannte Listenart'; end if;
  update public.lists set kind = p_kind where id = p_id and server_id = s.server_id and deleted_at is null;
  if not found then raise exception 'Liste nicht gefunden'; end if;
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
     and (s.role = 'admin' or coalesce(public._list_day(date) + 5 >= public._today(), true));
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

revoke all on function public.set_list_kind(text, uuid, text) from public, authenticated;
grant execute on function public.set_list_kind(text, uuid, text) to anon;

notify pgrst, 'reload schema';
