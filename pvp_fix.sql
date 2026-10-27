-- Jambling: 1v1 fixes. Run once in Supabase > SQL Editor.
--  * "Finish your current match first" while no match is on screen: you could end up in two live matches at once
--    (accepting a challenge while one you sent also got accepted). Accepting now also checks the challenger is free.
--  * The 1v1 screen now always shows a live match first (it used to show the newest match, even if that one had ended).

create or replace function pvp_accept(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; bal numeric;
begin
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and b = me for update;
  if not found or m.status <> 'pending' then raise exception 'That challenge is gone'; end if;
  if exists (select 1 from pvp_matches where (a = me or b = me) and status = 'live') then raise exception 'Finish your current match first'; end if;
  if exists (select 1 from pvp_matches where (a = m.a or b = m.a) and status = 'live') then raise exception 'They''re in another match right now. Try again in a minute.'; end if;
  if not m.friendly then
    select balance into bal from profiles where id = me for update;
    if bal - m.stake < 1000 then raise exception 'You need % coins above 1,000 to accept', m.stake; end if;
    update profiles set balance = balance - m.stake where id = me;
  end if;
  if m.game = 'filler' then
    declare brd int[] := _filler_start(); own0 int[];
    begin
      select array_agg(case when i = 37 then 1 when i = 6 then 2 else 0 end) into own0 from generate_series(1,42) i;
      update pvp_matches set status = 'live', fb = brd, fo = own0, fturn = m.a, a_acted = now(), b_acted = now() where id = m.id;
    end;
  elsif m.game = 'archer' then
    update pvp_matches set status = 'live', ax = 15, bx = 85, a_hp = 100, b_hp = 100, round = 0, log = '[]',
           rt_start = now(), a_hit_at = null, b_hit_at = null, a_acted = now(), b_acted = now() where id = m.id;
  else
    update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
           a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
     where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  perform _settle_poison();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by (status = 'live') desc, created_at desc limit 1;   -- a live match always shows, even if a newer one already finished
  if cur.id is not null and cur.status = 'live' and cur.game = 'archer' then
    if cur.a = me then update pvp_matches set a_acted = now() where id = cur.id;
    else update pvp_matches set b_acted = now() where id = cur.id; end if;
  end if;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

-- clean up anyone currently stuck in more than one live match: keep the newest, settle the older ones as a draw (stakes back)
do $$
declare r record;
begin
  for r in select m.id from pvp_matches m
            where m.status = 'live'
              and exists (select 1 from pvp_matches n where n.status = 'live' and n.id <> m.id and n.created_at > m.created_at
                          and (n.a in (m.a, m.b) or n.b in (m.a, m.b))) loop
    perform _pvp_finish(r.id, null, 'tie');
  end loop;
end $$;

notify pgrst, 'reload schema';
