-- Update 7: Kategorien (nach update-6-geraete-sperren.sql ausführen)
-- Kategorien werden im Browser automatisch erkannt. Hier wird nur gespeichert,
-- wenn ein Admin die Kategorie eines Eintrags von Hand ändert ('' = automatisch).

alter table public.items add column if not exists category text not null default '';

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

create or replace function public.set_item_category(p_token text, p_id uuid, p_category text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  if s.role <> 'admin' then raise exception 'Nur für Admins'; end if;
  if coalesce(p_category, '') not in ('', 'brot', 'herzhaft', 'suess', 'obst', 'getraenke', 'sonstiges') then
    raise exception 'Unbekannte Kategorie';
  end if;
  update public.items i set category = coalesce(p_category, '')
    from public.lists l
   where l.id = i.list_id and i.id = p_id and l.server_id = s.server_id;
  if not found then raise exception 'Eintrag nicht gefunden'; end if;
end $$;

revoke all on function public.set_item_category(text, uuid, text) from public, authenticated;
grant execute on function public.set_item_category(text, uuid, text) to anon;

notify pgrst, 'reload schema';
