-- Update 4: Emoji pro Server (nach update-3-server.sql ausführen)
alter table public.servers add column if not exists emoji text not null default '🥐';

create or replace function public.server_info(p_server text default '')
returns json language sql security definer set search_path = public, extensions as $$
  select json_build_object('name', name, 'slug', slug, 'emoji', emoji) from public.servers where slug = public._norm_slug(p_server);
$$;

create or replace function public.me(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._session(p_token);
begin
  return json_build_object('role', s.role, 'uid', s.uid,
    'server', (select name from public.servers where id = s.server_id),
    'emoji', (select emoji from public.servers where id = s.server_id));
end $$;

create or replace function public.super_servers(p_token text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token);
begin
  return coalesce((select json_agg(json_build_object(
      'id', v.id, 'slug', v.slug, 'name', v.name, 'emoji', v.emoji, 'created_at', v.created_at,
      'lists', (select count(*) from public.lists l where l.server_id = v.id),
      'items', (select count(*) from public.items i join public.lists l on l.id = i.list_id where l.server_id = v.id)
    ) order by (v.slug = '') desc, v.created_at) from public.servers v), '[]'::json);
end $$;

create or replace function public.super_set_server_emoji(p_token text, p_id uuid, p_emoji text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s public.sessions := public._super(p_token);
begin
  update public.servers set emoji = coalesce(nullif(left(trim(coalesce(p_emoji, '')), 16), ''), '🥐') where id = p_id;
  if not found then raise exception 'Server nicht gefunden'; end if;
end $$;

revoke all on function public.super_set_server_emoji(text, uuid, text) from public, authenticated;
grant execute on function public.super_set_server_emoji(text, uuid, text) to anon;

notify pgrst, 'reload schema';
