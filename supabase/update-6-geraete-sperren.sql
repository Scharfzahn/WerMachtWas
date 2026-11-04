-- Update 6: Geräte sperren (nach update-5-papierkorb.sql ausführen)
-- Admins sehen, welche Einträge vom selben Gerät kommen, und können ein Gerät sperren.
-- Gerätekennungen werden nicht mehr an Schüler*innen geschickt.

create table if not exists public.blocked_devices (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  uid text not null,
  sample text not null default '',
  blocked_at timestamptz not null default now(),
  unique (server_id, uid)
);
alter table public.blocked_devices enable row level security;
revoke all on public.blocked_devices from anon, authenticated;

-- Kurzer, anonymer Gerätecode nur für Admins (z. B. a3f9)
create or replace function public._device_tag(p_server uuid, p_uid text)
returns text language sql immutable as $$ select left(md5(p_server::text || ':' || p_uid), 4); $$;

create or replace function public._is_blocked(p_server uuid, p_uid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocked_devices where server_id = p_server and uid = p_uid);
$$;
revoke all on function public._device_tag(uuid, text), public._is_blocked(uuid, text) from public, anon, authenticated;

create or replace function public.me(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  return json_build_object('role', s.role, 'uid', s.uid,
    'server', (select name from public.servers where id = s.server_id),
    'emoji', (select emoji from public.servers where id = s.server_id),
    'blocked', s.role <> 'admin' and public._is_blocked(s.server_id, s.uid));
end $$;

create or replace function public.get_lists(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); adm boolean := s.role = 'admin';
begin
  return coalesce((
    select json_agg(json_build_object(
      'id', l.id, 'title', l.title, 'date', l.date, 'note', l.note, 'emoji', l.emoji,
      'expired', coalesce(public._list_day(l.date) < public._today(), false),
      'hidden', coalesce(public._list_day(l.date) + 5 < public._today(), false),
      'items', coalesce((select json_agg(json_build_object(
          'id', i.id, 'what', i.what, 'who', i.who, 'done', i.done,
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

create or replace function public.add_item(p_token text, p_list_id uuid, p_what text, p_who text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); i public.items;
begin
  if s.role <> 'admin' and public._is_blocked(s.server_id, s.uid) then
    raise exception 'Dieses Gerät wurde von einem Admin gesperrt';
  end if;
  if coalesce(trim(p_what), '') = '' then raise exception 'Eintrag fehlt'; end if;
  if not exists (select 1 from public.lists where id = p_list_id and server_id = s.server_id and deleted_at is null
                 and (s.role = 'admin' or coalesce(public._list_day(date) + 5 >= public._today(), true))) then
    raise exception 'Liste nicht gefunden';
  end if;
  if (select count(*) from public.items where list_id = p_list_id and deleted_at is null) >= 300 then raise exception 'Liste ist voll'; end if;
  insert into public.items(list_id, what, who, owner)
    values (p_list_id, left(trim(p_what), 150), left(trim(coalesce(p_who, '')), 60), s.uid)
    returning * into i;
  return json_build_object('id', i.id, 'what', i.what, 'who', i.who, 'done', i.done, 'mine', true,
    'device', case when s.role = 'admin' then public._device_tag(s.server_id, s.uid) end, 'blocked', false);
end $$;

-- Gerät sperren, das einen bestimmten Eintrag geschrieben hat. Optional alle seine Einträge in den Papierkorb.
create or replace function public.block_device(p_token text, p_item_id uuid, p_delete_all boolean default false)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token); o text; w text; n int := 0;
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  select i.owner, i.what || coalesce(' – ' || nullif(i.who, ''), '') into o, w
    from public.items i join public.lists l on l.id = i.list_id
   where i.id = p_item_id and l.server_id = s.server_id;
  if o is null then raise exception 'Eintrag nicht gefunden'; end if;
  if o = s.uid then raise exception 'Du kannst dein eigenes Gerät nicht sperren'; end if;
  insert into public.blocked_devices(server_id, uid, sample) values (s.server_id, o, left(w, 200))
    on conflict (server_id, uid) do nothing;
  if p_delete_all then
    update public.items i set deleted_at = now()
      from public.lists l
     where l.id = i.list_id and l.server_id = s.server_id and i.owner = o and i.deleted_at is null;
    get diagnostics n = row_count;
  end if;
  return json_build_object('deleted', n);
end $$;

create or replace function public.get_blocked(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', b.id, 'device', public._device_tag(b.server_id, b.uid), 'sample', b.sample, 'blocked_at', b.blocked_at)
      order by b.blocked_at desc)
    from public.blocked_devices b where b.server_id = s.server_id), '[]'::json);
end $$;

create or replace function public.unblock_device(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  delete from public.blocked_devices where id = p_id and server_id = s.server_id;
end $$;

revoke all on function public.block_device(text, uuid, boolean), public.get_blocked(text), public.unblock_device(text, uuid) from public, authenticated;
grant execute on function public.block_device(text, uuid, boolean), public.get_blocked(text), public.unblock_device(text, uuid) to anon;

notify pgrst, 'reload schema';
