-- Jambling: Archers special arrows you buy once and keep. Run once in Supabase > SQL Editor (after archer_rt.sql + archer_dmg2.sql).
--   Poison arrow (1b): normal hit, then 4 HP/sec for 3 seconds.
--   Homing arrow (5b): steers slightly toward the target mid-flight.
-- The server records who owns what; a client only honors an opponent's special arrow if that opponent actually owns it.

create table if not exists archer_owned (
  user_id uuid not null references profiles(id) on delete cascade,
  kind text not null check (kind in ('poison', 'homing')),
  bought_at timestamptz not null default now(),
  primary key (user_id, kind)
);
alter table archer_owned enable row level security;   -- functions only

create or replace function _archer_price(p_kind text) returns numeric language sql immutable as $$
  select case p_kind when 'poison' then 1000000000::numeric when 'homing' then 5000000000::numeric end
$$;

create or replace function _archer_owned(p_uid uuid) returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(kind order by kind), '[]'::json) from archer_owned where user_id = p_uid
$$;
revoke execute on function _archer_owned(uuid) from public, anon, authenticated;

-- what I own + prices (for the arrow picker)
create or replace function archer_arrows() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('owned', _archer_owned(auth.uid()),
                           'prices', json_build_object('poison', _archer_price('poison'), 'homing', _archer_price('homing')))
$$;

create or replace function archer_buy(p_kind text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); price numeric := _archer_price(p_kind); bal numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if price is null then raise exception 'Unknown arrow'; end if;
  if exists (select 1 from archer_owned where user_id = me and kind = p_kind) then raise exception 'You already own that arrow'; end if;
  select balance into bal from profiles where id = me for update;
  if bal < price then raise exception 'You need % coins', to_char(price, 'FM999,999,999,999'); end if;
  update profiles set balance = balance - price where id = me returning balance into bal;
  insert into archer_owned (user_id, kind) values (me, p_kind);
  return json_build_object('owned', _archer_owned(me), 'balance', bal);
end $$;
revoke execute on function archer_buy(text) from anon;

-- damage now carries a kind: 'hit' (one arrow, 1-56, de-duped) or 'poison' (a tick, max 4)
drop function if exists archer_damage(uuid, int);
create or replace function archer_damage(p_id uuid, p_dmg int, p_kind text default 'hit') returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; last_hit timestamptz; hp int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_dmg is null or p_dmg < 1 or p_dmg > 56 then raise exception 'Bad damage'; end if;   -- body 10-35, headshot up to 56
  if p_kind not in ('hit', 'poison') then raise exception 'Bad damage kind'; end if;
  if p_kind = 'poison' and p_dmg > 4 then raise exception 'Bad poison tick'; end if;
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'archer' then
    select * into m from pvp_matches where id = p_id;
    return _pvp_view(m, me);
  end if;
  is_a := m.a = me;
  last_hit := case when is_a then m.a_hit_at else m.b_hit_at end;
  if p_kind = 'hit' and last_hit is not null and clock_timestamp() - last_hit < interval '250 milliseconds' then   -- one arrow can't count twice (poison ticks exempt)
    return _pvp_view(m, me);
  end if;
  hp := greatest(0, (case when is_a then m.a_hp else m.b_hp end) - p_dmg);
  if is_a then
    update pvp_matches set a_hp = hp, a_hit_at = case when p_kind = 'hit' then clock_timestamp() else a_hit_at end, a_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'a', 'dmg', p_dmg, 'kind', p_kind, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  else
    update pvp_matches set b_hp = hp, b_hit_at = case when p_kind = 'hit' then clock_timestamp() else b_hit_at end, b_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'b', 'dmg', p_dmg, 'kind', p_kind, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  end if;
  if hp <= 0 then perform _pvp_finish(m.id, case when is_a then m.b else m.a end, 'win'); end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function archer_damage(uuid, int, text) from anon;

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

notify pgrst, 'reload schema';
