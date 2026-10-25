-- Jambling: 1v1 "Archers" — REAL-TIME. Run once in Supabase > SQL Editor (replaces the turn-based archer.sql).
-- Movement, jumps, aiming and arrows sync player-to-player over Supabase Realtime (websocket broadcast, no DB per frame).
-- The database only owns HP, the 90-second clock and the payout:
--   * a player can only report damage to THEMSELVES (archer_damage), so nobody can fake hits on the other guy
--   * 90s match: most HP wins (tie = stakes back). Leave the game for 25s = forfeit.
--   Body 25 · Headshot 40 · 100 HP each.

alter table pvp_matches add column if not exists a_hp int not null default 100;
alter table pvp_matches add column if not exists b_hp int not null default 100;
alter table pvp_matches add column if not exists round int not null default 1;
alter table pvp_matches add column if not exists log jsonb not null default '[]';
alter table pvp_matches add column if not exists ax numeric;
alter table pvp_matches add column if not exists bx numeric;
alter table pvp_matches add column if not exists rt_start timestamptz;
alter table pvp_matches add column if not exists a_hit_at timestamptz;
alter table pvp_matches add column if not exists b_hit_at timestamptz;

-- old turn-based shot RPC: dead
create or replace function archer_shoot(p_id uuid, p_jump int, p_angle numeric, p_power numeric) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Archers was updated. Refresh the page.'; end $$;

-- ---------- challenge: allow the game ----------
create or replace function pvp_challenge(p_user text, p_stake numeric, p_friendly boolean, p_game text default 'duel') returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); them uuid; bal numeric; m pvp_matches;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_game not in ('duel','filler','archer') then p_game := 'duel'; end if;
  perform _pvp_tidy();
  select id into them from profiles where lower(username) = lower(trim(p_user)) and not banned order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if them = me then raise exception 'You can''t challenge yourself'; end if;
  if exists (select 1 from pvp_matches where (a = me or b = me) and status = 'live') then raise exception 'Finish your current match first'; end if;
  if exists (select 1 from pvp_matches where a = me and status = 'pending') then raise exception 'You already have a challenge waiting. Cancel it first.'; end if;
  if p_friendly then p_stake := 0;
  else
    p_stake := round(p_stake, 2);
    if p_stake is null or p_stake <= 0 then raise exception 'Enter a stake'; end if;
    select balance into bal from profiles where id = me for update;
    if bal - p_stake < 1000 then raise exception 'You can only stake coins above 1,000 (you can stake %)', greatest(0, bal - 1000); end if;
    update profiles set balance = balance - p_stake where id = me;
  end if;
  insert into pvp_matches (a, b, stake, friendly, game) values (me, them, p_stake, p_friendly, p_game) returning * into m;
  return _pvp_view(m, me);
end $$;

-- ---------- accept: start the clock ----------
create or replace function pvp_accept(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; bal numeric;
begin
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and b = me for update;
  if not found or m.status <> 'pending' then raise exception 'That challenge is gone'; end if;
  if exists (select 1 from pvp_matches where (a = me or b = me) and status = 'live') then raise exception 'Finish your current match first'; end if;
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

-- ---------- I got hit: lower MY OWN hp (only ever your own) ----------
create or replace function archer_damage(p_id uuid, p_dmg int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; last_hit timestamptz; hp int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_dmg not in (25, 40) then raise exception 'Bad damage'; end if;
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'archer' then
    select * into m from pvp_matches where id = p_id;
    return _pvp_view(m, me);
  end if;
  is_a := m.a = me;
  last_hit := case when is_a then m.a_hit_at else m.b_hit_at end;
  if last_hit is not null and clock_timestamp() - last_hit < interval '250 milliseconds' then   -- one arrow can't count twice
    return _pvp_view(m, me);
  end if;
  hp := greatest(0, (case when is_a then m.a_hp else m.b_hp end) - p_dmg);
  if is_a then
    update pvp_matches set a_hp = hp, a_hit_at = clock_timestamp(), a_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'a', 'dmg', p_dmg, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  else
    update pvp_matches set b_hp = hp, b_hit_at = clock_timestamp(), b_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'b', 'dmg', p_dmg, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  end if;
  if hp <= 0 then perform _pvp_finish(m.id, case when is_a then m.b else m.a end, 'win'); end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function archer_damage(uuid, int) from anon;

-- ---------- view ----------
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end; sl numeric;
begin
  if m.game = 'archer' then
    sl := case when m.status = 'live' and m.rt_start is not null then greatest(0, 90 - extract(epoch from now() - m.rt_start)) end;
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'archer', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'secs_left', sl, 'me_side', case when is_a then 'left' else 'right' end,
      'my_hp', case when is_a then m.a_hp else m.b_hp end, 'opp_hp', case when is_a then m.b_hp else m.a_hp end,
      'my_x', case when is_a then m.ax else m.bx end, 'opp_x', case when is_a then m.bx else m.ax end,
      'hits', m.round, 'log', m.log,
      'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
      'balance', (select balance from profiles where id = me));
  end if;
  if m.game = 'filler' then
    sl := case when m.status = 'live' and m.fturn = me
               then greatest(0, 15 - extract(epoch from now() - case when is_a then m.a_acted else m.b_acted end)) end;
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'filler', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'board', m.fb, 'owner', m.fo, 'me_p', p,
      'my_turn', m.fturn = me, 'secs_left', sl,
      'my_color', _filler_color(m.fb, m.fo, p), 'opp_color', _filler_color(m.fb, m.fo, 3 - p),
      'my_count', _filler_count(m.fo, p), 'opp_count', _filler_count(m.fo, 3 - p),
      'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
      'balance', (select balance from profiles where id = me));
  end if;
  sl := case when m.status = 'live' and (case when is_a then m.a_move else m.b_move end) is null
             then greatest(0, 15 - extract(epoch from now() - case when is_a then m.a_acted else m.b_acted end)) end;
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'duel', 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round, 'streak', m.streak, 'attacking', m.attacker = me,
    'my_move', case when is_a then m.a_move else m.b_move end,
    'my_last', case when is_a then m.a_last else m.b_last end,
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'secs_left', sl, 'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- ---------- housekeeping: 90s clock + "left the game" forfeit ----------
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; idle uuid;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.game = 'archer' then
      if m.rt_start is not null and now() >= m.rt_start + interval '90 seconds' then
        if m.a_hp > m.b_hp then perform _pvp_finish(m.id, m.a, 'win');
        elsif m.b_hp > m.a_hp then perform _pvp_finish(m.id, m.b, 'win');
        else perform _pvp_finish(m.id, null, 'tie'); end if;
      elsif m.a_acted < now() - interval '25 seconds' then perform _pvp_finish(m.id, m.b, 'win');   -- a left
      elsif m.b_acted < now() - interval '25 seconds' then perform _pvp_finish(m.id, m.a, 'win');   -- b left
      end if;
    elsif m.game = 'filler' then
      idle := case when m.fturn = m.a and m.a_acted < now() - interval '15 seconds' then m.a
                   when m.fturn = m.b and m.b_acted < now() - interval '15 seconds' then m.b end;
      if idle is not null then perform _pvp_finish(m.id, case when idle = m.a then m.b else m.a end, 'win'); end if;
    else
      if m.a_move is null and m.a_acted < now() - interval '15 seconds'
         and m.b_move is null and m.b_acted < now() - interval '15 seconds' then perform _pvp_finish(m.id, null, 'tie');
      elsif m.a_move is null and m.a_acted < now() - interval '15 seconds' then perform _pvp_finish(m.id, m.b, 'win');
      elsif m.b_move is null and m.b_acted < now() - interval '15 seconds' then perform _pvp_finish(m.id, m.a, 'win');
      else perform _box_resolve(m.id); end if;
    end if;
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- ---------- state poll: also counts as "still here" for a live archer match ----------
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  perform _settle_poison();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
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

notify pgrst, 'reload schema';
