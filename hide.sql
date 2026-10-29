-- Jambling: 1v1 Chameleon (Meccha Chameleon-style hide & seek in a 3D map). Run once in Supabase > SQL Editor (after archer_rt.sql / pvp_fix.sql / archer_upgrades.sql).
--   * Two rounds: each player hides once. 25s to hide, paint yourself and pose (the hunter is blind), then 60s for the hunter to find and shoot them.
--   * Whoever survives longer as the hider wins (both survive the full 60s or get tagged at the same second = draw).
--   * Hider gadgets (bought once, one use per round): Freeze, Smoke bomb, Decoy.
--   * Hide 25s + hunt 60s = 85s per round, 4s pause between rounds.

alter table pvp_matches add column if not exists hs_r1_end timestamptz;
alter table pvp_matches add column if not exists hs_r2_start timestamptz;
alter table pvp_matches add column if not exists hs_r2_end timestamptz;
alter table pvp_matches add column if not exists hs_t1 numeric;   -- seconds the challenger survived as hider
alter table pvp_matches add column if not exists hs_t2 numeric;   -- seconds the other player survived as hider

-- ---------- gadgets ----------
create table if not exists hs_owned (
  user_id uuid not null references profiles(id) on delete cascade,
  kind text not null, bought_at timestamptz not null default now(),
  primary key (user_id, kind)
);
alter table hs_owned enable row level security;   -- no policies: only the functions touch it

create or replace function _hs_price(p_kind text) returns numeric language sql immutable as $$
  select case p_kind when 'freeze' then 3000000000::numeric when 'smoke' then 2000000000::numeric when 'decoy' then 5000000000::numeric end
$$;
create or replace function _hs_owned(p_uid uuid) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(kind order by bought_at), '[]'::json) from hs_owned where user_id = p_uid
$$;
revoke execute on function _hs_owned(uuid) from public, anon, authenticated;

create or replace function hs_items() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('owned', _hs_owned(auth.uid()),
                           'prices', json_build_object('freeze', _hs_price('freeze'), 'smoke', _hs_price('smoke'), 'decoy', _hs_price('decoy')))
$$;
grant execute on function hs_items() to authenticated;

create or replace function hs_buy(p_kind text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); price numeric := _hs_price(p_kind); bal numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if price is null then raise exception 'Unknown gadget'; end if;
  if exists (select 1 from hs_owned where user_id = me and kind = p_kind) then raise exception 'You already own that'; end if;
  select balance into bal from profiles where id = me for update;
  if bal < price then raise exception 'You need % coins', to_char(price, 'FM999,999,999,999'); end if;
  update profiles set balance = balance - price where id = me returning balance into bal;
  insert into hs_owned (user_id, kind) values (me, p_kind);
  return json_build_object('owned', _hs_owned(me), 'balance', bal);
end $$;
revoke execute on function hs_buy(text) from anon;
grant execute on function hs_buy(text) to authenticated;

-- ---------- round clock ----------
-- round 1: challenger (a) hides, b seeks. round 2: swap. 12s hide + 60s seek, 4s pause between rounds.
create or replace function _hs_info(m pvp_matches) returns json
language plpgsql stable as $$
declare st timestamptz; el numeric; rnd int; hider uuid; phase text; secs numeric;
begin
  if m.rt_start is null then return null; end if;
  if m.hs_r1_end is null then rnd := 1; st := m.rt_start; hider := m.a;
  elsif m.hs_r2_start is not null and now() < m.hs_r2_start then rnd := 2; hider := m.b; phase := 'pause'; secs := extract(epoch from m.hs_r2_start - now());
  elsif m.hs_r2_end is null then rnd := 2; st := m.hs_r2_start; hider := m.b;
  else rnd := 2; hider := m.b; phase := 'done'; secs := 0; end if;
  if phase is null then
    el := extract(epoch from now() - st);
    if el < 25 then phase := 'hide'; secs := 25 - el; else phase := 'seek'; secs := greatest(0, 85 - el); end if;
  end if;
  return json_build_object('round', rnd, 'hider', hider, 'phase', phase, 'secs', round(secs::numeric, 1), 't1', m.hs_t1, 't2', m.hs_t2);
end $$;
revoke execute on function _hs_info(pvp_matches) from public, anon, authenticated;

create or replace function _hs_finish(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id;
  if m.hs_t1 > m.hs_t2 then perform _pvp_finish(m.id, m.a, 'win');
  elsif m.hs_t2 > m.hs_t1 then perform _pvp_finish(m.id, m.b, 'win');
  else perform _pvp_finish(m.id, null, 'tie'); end if;
end $$;
revoke execute on function _hs_finish(uuid) from public, anon, authenticated;

-- the seeker touched the hider (either player's game may report it; the first report counts)
create or replace function hide_catch(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; el numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'hide' then raise exception 'No live match'; end if;
  if m.hs_r1_end is null then
    el := extract(epoch from now() - m.rt_start);
    if el < 25 or el >= 85 then raise exception 'Not now'; end if;
    update pvp_matches set hs_r1_end = now(), hs_t1 = round((el - 25)::numeric, 1), hs_r2_start = now() + interval '4 seconds', a_acted = now(), b_acted = now() where id = m.id;
  elsif m.hs_r2_start is not null and m.hs_r2_end is null and now() >= m.hs_r2_start then
    el := extract(epoch from now() - m.hs_r2_start);
    if el < 25 or el >= 85 then raise exception 'Not now'; end if;
    update pvp_matches set hs_r2_end = now(), hs_t2 = round((el - 25)::numeric, 1), a_acted = now(), b_acted = now() where id = m.id;
    perform _hs_finish(m.id);
  else raise exception 'Not now'; end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function hide_catch(uuid) from anon;
grant execute on function hide_catch(uuid) to authenticated;

-- ---------- challenge / accept / view / tidy / state know about 'hide' ----------
create or replace function pvp_challenge(p_user text, p_stake numeric, p_friendly boolean, p_game text default 'duel') returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); them uuid; bal numeric; m pvp_matches;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_game not in ('duel','filler','archer','hide') then p_game := 'duel'; end if;
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
    update pvp_matches set status = 'live', ax = 15, bx = 85, a_hp = _archer_maxhp(m.a), b_hp = _archer_maxhp(m.b),
           a_max = _archer_maxhp(m.a), b_max = _archer_maxhp(m.b), round = 0, log = '[]',
           rt_start = now(), a_hit_at = null, b_hit_at = null, a_acted = now(), b_acted = now() where id = m.id;
  elsif m.game = 'hide' then
    update pvp_matches set status = 'live', rt_start = now(), hs_r1_end = null, hs_r2_start = null, hs_r2_end = null, hs_t1 = null, hs_t2 = null,
           round = 0, log = '[]', a_acted = now(), b_acted = now() where id = m.id;
  else
    update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
           a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
     where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end; sl numeric;
begin
  if m.game = 'hide' then
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'hide', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'hs', _hs_info(m),
      'my_time', case when is_a then m.hs_t1 else m.hs_t2 end, 'opp_time', case when is_a then m.hs_t2 else m.hs_t1 end,
      'my_items', _hs_owned(me),
      'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
      'balance', (select balance from profiles where id = me));
  end if;
  if m.game = 'archer' then
    sl := case when m.status = 'live' and m.rt_start is not null then greatest(0, 90 - extract(epoch from now() - m.rt_start)) end;
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'archer', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'secs_left', sl, 'me_side', case when is_a then 'left' else 'right' end,
      'my_hp', case when is_a then m.a_hp else m.b_hp end, 'opp_hp', case when is_a then m.b_hp else m.a_hp end,
      'my_x', case when is_a then m.ax else m.bx end, 'opp_x', case when is_a then m.bx else m.ax end,
      'hits', m.round, 'log', m.log,
      'my_arrows', _archer_owned(me), 'opp_arrows', _archer_owned(case when is_a then m.b else m.a end),
      'my_max', case when is_a then coalesce(m.a_max, 100) else coalesce(m.b_max, 100) end, 'opp_max', case when is_a then coalesce(m.b_max, 100) else coalesce(m.a_max, 100) end,
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
    if m.game = 'hide' then
      if m.rt_start is null then continue; end if;
      if m.hs_r1_end is null and now() >= m.rt_start + interval '85 seconds' then   -- round 1: the hider survived
        update pvp_matches set hs_r1_end = m.rt_start + interval '85 seconds', hs_t1 = 60, hs_r2_start = m.rt_start + interval '89 seconds' where id = m.id;
      elsif m.hs_r2_start is not null and m.hs_r2_end is null and now() >= m.hs_r2_start + interval '85 seconds' then   -- round 2: survived
        update pvp_matches set hs_r2_end = m.hs_r2_start + interval '85 seconds', hs_t2 = 60 where id = m.id;
        perform _hs_finish(m.id);
      elsif m.a_acted < now() - interval '25 seconds' then perform _pvp_finish(m.id, m.b, 'win');   -- a left
      elsif m.b_acted < now() - interval '25 seconds' then perform _pvp_finish(m.id, m.a, 'win');   -- b left
      end if;
    elsif m.game = 'archer' then
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

create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  perform _settle_poison();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by (status = 'live') desc, created_at desc limit 1;   -- a live match always shows, even if a newer one already finished
  if cur.id is not null and cur.status = 'live' and cur.game in ('archer', 'hide') then
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
