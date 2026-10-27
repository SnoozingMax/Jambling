-- Jambling: Archers upgrades. Run once in Supabase > SQL Editor (after archer_arrows.sql and pvp_fix.sql).
--   Sniper arrow (2b): fast and nearly flat. Body 0.6x damage, headshot 2.2x.
--   Lifesteal arrow (8b): heals you for half the damage it does (never above your max HP).
--   200 HP (5b): start every Archers match with 200 HP instead of 100.
-- Ownership is checked on the server: lifesteal only heals, and 200 HP only applies, if you actually bought it.

alter table archer_owned drop constraint if exists archer_owned_kind_check;
alter table archer_owned add constraint archer_owned_kind_check check (kind in ('poison', 'homing', 'sniper', 'vampire', 'hp200'));
alter table pvp_matches add column if not exists a_max int not null default 100;
alter table pvp_matches add column if not exists b_max int not null default 100;

create or replace function _archer_price(p_kind text) returns numeric language sql immutable as $$
  select case p_kind when 'poison' then 1000000000::numeric when 'homing' then 5000000000::numeric
                     when 'sniper' then 2000000000::numeric when 'vampire' then 8000000000::numeric
                     when 'hp200' then 5000000000::numeric end
$$;
create or replace function _archer_maxhp(p_uid uuid) returns int language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from archer_owned where user_id = p_uid and kind = 'hp200') then 200 else 100 end
$$;
revoke execute on function _archer_maxhp(uuid) from public, anon, authenticated;

create or replace function archer_arrows() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('owned', _archer_owned(auth.uid()), 'max_hp', _archer_maxhp(auth.uid()),
                           'prices', json_build_object('poison', _archer_price('poison'), 'homing', _archer_price('homing'),
                                                       'sniper', _archer_price('sniper'), 'vampire', _archer_price('vampire'), 'hp200', _archer_price('hp200')))
$$;

-- damage kinds: 'hit' (1-90, de-duped), 'vamp' (a lifesteal arrow hit: also heals the shooter by half, if they own it), 'poison' (tick, max 4)
create or replace function archer_damage(p_id uuid, p_dmg int, p_kind text default 'hit') returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; last_hit timestamptz; hp int; shooter uuid; heal int := 0;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_kind not in ('hit', 'vamp', 'poison') then raise exception 'Bad damage kind'; end if;
  if p_dmg is null or p_dmg < 1 or p_dmg > 90 then raise exception 'Bad damage'; end if;   -- sniper headshot tops out ~77
  if p_kind = 'poison' and p_dmg > 4 then raise exception 'Bad poison tick'; end if;
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'archer' then
    select * into m from pvp_matches where id = p_id;
    return _pvp_view(m, me);
  end if;
  is_a := m.a = me; shooter := case when is_a then m.b else m.a end;
  last_hit := case when is_a then m.a_hit_at else m.b_hit_at end;
  if p_kind <> 'poison' and last_hit is not null and clock_timestamp() - last_hit < interval '250 milliseconds' then
    return _pvp_view(m, me);
  end if;
  if p_kind = 'vamp' and exists (select 1 from archer_owned where user_id = shooter and kind = 'vampire') then heal := p_dmg / 2; end if;
  hp := greatest(0, (case when is_a then m.a_hp else m.b_hp end) - p_dmg);
  if is_a then
    update pvp_matches set a_hp = hp, b_hp = least(coalesce(b_max, 100), b_hp + heal),
           a_hit_at = case when p_kind <> 'poison' then clock_timestamp() else a_hit_at end, a_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'a', 'dmg', p_dmg, 'kind', p_kind, 'heal', heal, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  else
    update pvp_matches set b_hp = hp, a_hp = least(coalesce(a_max, 100), a_hp + heal),
           b_hit_at = case when p_kind <> 'poison' then clock_timestamp() else b_hit_at end, b_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'b', 'dmg', p_dmg, 'kind', p_kind, 'heal', heal, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  end if;
  if hp <= 0 then perform _pvp_finish(m.id, shooter, 'win'); end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function archer_damage(uuid, int, text) from anon;

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

notify pgrst, 'reload schema';
