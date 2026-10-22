-- Jambling: Poison shop item - 10b to drain 1b/sec from the top player for 10 seconds. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists poison_until timestamptz;
alter table profiles add column if not exists poison_tick  timestamptz;

-- lazily drain any poisoned player by the whole seconds elapsed since the last tick (can't be dodged)
create or replace function _settle_poison() returns void
language plpgsql security definer set search_path = public as $$
declare r record; secs int;
begin
  for r in select id, poison_until, poison_tick from profiles where poison_until is not null for update loop
    secs := floor(extract(epoch from least(clock_timestamp(), r.poison_until) - r.poison_tick))::int;
    if secs > 0 then
      update profiles set balance = greatest(0, balance - secs::numeric * 1e9),
             poison_tick = r.poison_tick + (secs || ' seconds')::interval
       where id = r.id;
    end if;
    if clock_timestamp() >= r.poison_until then
      update profiles set poison_until = null, poison_tick = null where id = r.id;
    end if;
  end loop;
end $$;
revoke execute on function _settle_poison() from public, anon, authenticated;

-- buy poison: pay 10b, poison the current richest player (not the owner) for 10s
create or replace function shop_poison() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e10; bal numeric; top uuid; tname text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 10 billion coins for Poison'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform _settle_poison();
  select id, username into top, tname from profiles
   where approved and not banned and not exists (select 1 from site_owner o where o.id = profiles.id)
   order by balance desc limit 1;
  if top is null then raise exception 'No one to poison'; end if;
  update profiles set poison_until = clock_timestamp() + interval '10 seconds', poison_tick = clock_timestamp() where id = top;
  return json_build_object('ok', true, 'balance', bal, 'target', tname);
end $$;
revoke execute on function shop_poison() from anon;

-- client calls this each second to advance the drain
create or replace function poison_pulse() returns json
language plpgsql security definer set search_path = public as $$
begin perform _settle_poison(); return json_build_object('ok', true); end $$;
revoke execute on function poison_pulse() from anon;

notify pgrst, 'reload schema';
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  perform _settle_poison();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

notify pgrst, 'reload schema';
