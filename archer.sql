-- Jambling: 1v1 "Archers". Run once in Supabase > SQL Editor.
-- Turn-based so lag never matters. Each turn: hop (back / stay / forward), then aim + pull back and fire.
-- The SERVER simulates the arrow (gravity arc) and decides hits, so a hit can't be faked.
--   Body hit 25 dmg · Headshot 40 dmg · 100 HP each · 15s to shoot or you forfeit · 40-shot cap (more HP wins).

alter table pvp_matches add column if not exists ax numeric;   -- left archer x (player a)
alter table pvp_matches add column if not exists bx numeric;   -- right archer x (player b)
-- a_hp, b_hp, round (shot count), log, fturn (whose turn) already exist

-- ---------- physics: MUST match the client exactly (same constants, same semi-implicit Euler order) ----------
-- field x 0..100, ground y 0. Bow at y 4.5. Opponent hitbox: |x-ox| <= 1.6, 0 <= y <= 6; head is y >= 4.6.
create or replace function _archer_sim(x0 numeric, dir int, angle numeric, power numeric, ox numeric) returns jsonb
language plpgsql immutable as $$
declare v float8; vx float8; vy float8; x float8 := x0; y float8 := 4.5; t float8 := 0;
        dt float8 := 0.02; g float8 := 30; hit text := 'none'; a float8;
begin
  v := 10 + power * 0.45;                     -- pull-back strength 0..100 -> speed 10..55
  a := radians(angle);
  vx := v * cos(a) * dir; vy := v * sin(a);
  loop
    t := t + dt;
    vy := vy - g * dt;
    x := x + vx * dt;
    y := y + vy * dt;
    if y <= 0 then y := 0; exit; end if;
    if x < -5 or x > 105 then exit; end if;
    if abs(x - ox) <= 1.6 and y <= 6 then
      hit := case when y >= 4.6 then 'head' else 'body' end;
      exit;
    end if;
    if t > 20 then exit; end if;
  end loop;
  return jsonb_build_object('hit', hit, 'x', round(x::numeric, 2), 'y', round(y::numeric, 2), 't', round(t::numeric, 2));
end $$;
revoke execute on function _archer_sim(numeric, int, numeric, numeric, numeric) from public, anon, authenticated;

-- ---------- challenge: allow the new game ----------
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

-- ---------- accept: set up the field ----------
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
    update pvp_matches set status = 'live', ax = 15, bx = 85, a_hp = 100, b_hp = 100, fturn = m.a, round = 0, log = '[]',
           a_acted = now(), b_acted = now() where id = m.id;
  else
    update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
           a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
     where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- ---------- the shot ----------
create or replace function archer_shoot(p_id uuid, p_jump int, p_angle numeric, p_power numeric) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; myx numeric; ox numeric; dir int;
        res jsonb; dmg int; hit text; newhp int; zmin numeric; zmax numeric; entry jsonb;
begin
  if me is null then raise exception 'Not signed in'; end if;
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'archer' then raise exception 'No match in play'; end if;
  if m.fturn <> me then raise exception 'Not your turn'; end if;
  if p_jump is null or p_jump not in (-1, 0, 1) then raise exception 'Bad hop'; end if;
  if p_angle is null or p_angle < 0 or p_angle > 90 then raise exception 'Bad angle'; end if;
  if p_power is null or p_power < 0 or p_power > 100 then raise exception 'Bad power'; end if;
  is_a := m.a = me;
  if is_a then zmin := 5;  zmax := 45; myx := m.ax; ox := m.bx; dir := 1;
  else         zmin := 55; zmax := 95; myx := m.bx; ox := m.ax; dir := -1; end if;
  myx := least(zmax, greatest(zmin, myx + p_jump * 8 * dir));           -- hop 8 units toward (+1) / away from (-1) the opponent, stays in your zone
  res := _archer_sim(myx, dir, p_angle, p_power, ox);
  hit := res->>'hit';
  dmg := case hit when 'head' then 40 when 'body' then 25 else 0 end;
  newhp := greatest(0, (case when is_a then m.b_hp else m.a_hp end) - dmg);
  entry := jsonb_build_object('by', case when is_a then 'a' else 'b' end, 'jump', p_jump, 'angle', p_angle, 'power', p_power,
                              'from', myx, 'hit', hit, 'dmg', dmg, 'x', res->'x', 'y', res->'y', 't', res->'t', 'hp', newhp);
  if is_a then
    update pvp_matches set ax = myx, b_hp = newhp, fturn = m.b, round = m.round + 1, log = log || entry,
           a_acted = now(), b_acted = now() where id = m.id;
  else
    update pvp_matches set bx = myx, a_hp = newhp, fturn = m.a, round = m.round + 1, log = log || entry,
           a_acted = now(), b_acted = now() where id = m.id;
  end if;
  if newhp <= 0 then
    perform _pvp_finish(m.id, me, 'win');
  elsif m.round + 1 >= 40 then                                         -- shot cap: more HP wins
    select * into m from pvp_matches where id = p_id;
    if m.a_hp > m.b_hp then perform _pvp_finish(m.id, m.a, 'win');
    elsif m.b_hp > m.a_hp then perform _pvp_finish(m.id, m.b, 'win');
    else perform _pvp_finish(m.id, null, 'tie'); end if;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function archer_shoot(uuid, int, numeric, numeric) from anon;

-- ---------- view: duel / filler / archer ----------
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end; sl numeric;
begin
  if m.game = 'archer' then
    sl := case when m.status = 'live' and m.fturn = me
               then greatest(0, 15 - extract(epoch from now() - case when is_a then m.a_acted else m.b_acted end)) end;
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'archer', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'my_turn', m.fturn = me, 'secs_left', sl,
      'me_side', case when is_a then 'left' else 'right' end,
      'my_hp', case when is_a then m.a_hp else m.b_hp end, 'opp_hp', case when is_a then m.b_hp else m.a_hp end,
      'my_x', case when is_a then m.ax else m.bx end, 'opp_x', case when is_a then m.bx else m.ax end,
      'shots', m.round, 'log', m.log,
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

-- ---------- housekeeping: archer forfeits after 15s on the clock, like filler ----------
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
    if m.game in ('filler', 'archer') then
      idle := case when m.fturn = m.a and m.a_acted < now() - interval '15 seconds' then m.a
                   when m.fturn = m.b and m.b_acted < now() - interval '15 seconds' then m.b end;
      if idle is not null then
        perform _pvp_finish(m.id, case when idle = m.a then m.b else m.a end, 'win');
      end if;
    else
      if m.a_move is null and m.a_acted < now() - interval '15 seconds'
         and m.b_move is null and m.b_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, null, 'tie');
      elsif m.a_move is null and m.a_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, m.b, 'win');
      elsif m.b_move is null and m.b_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, m.a, 'win');
      else
        perform _box_resolve(m.id);
      end if;
    end if;
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

notify pgrst, 'reload schema';
