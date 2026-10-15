-- Jambling: Mines (all-in-one: game + high risk high reward + 20m max win). Run once in Supabase > SQL Editor.

-- Jambling: Mines. Run once in Supabase > SQL Editor.
-- 5x5 grid. Pick how many bombs, flip tiles, multiplier climbs each safe tile, cash out any time.
-- Bombs are rolled on the server at the moment you tap, so nobody can read the board early.
-- Max bet 100k, max win 5m. Bad luck = every tile is a bomb. Rush hour / boost = fewer bombs hit.

create table if not exists mines_rounds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  mines int not null,
  revealed int[] not null default '{}',
  bombs int[],
  status text not null default 'live',      -- live / cashed / boom
  payout numeric not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists mines_rounds_user on mines_rounds (user_id, status);
alter table mines_rounds enable row level security;   -- no policies: only functions touch it

-- multiplier after k safe tiles with m bombs (3% house edge)
create or replace function _mines_mult(m int, k int) returns numeric
language sql immutable as $$
  select case when k <= 0 then 1::numeric
    else round(floor(0.97 * exp(coalesce((select sum(ln((25 - i)::numeric / (25 - m - i))) from generate_series(0, k - 1) i), 0)) * 100) / 100, 2) end
$$;

create or replace function _mines_payout(r mines_rounds) returns numeric
language sql stable security definer set search_path = public as $$
  select least(r.bet + 5000000,
               round(r.bet + r.bet * (_mines_mult(r.mines, cardinality(r.revealed)) - 1) * _luck(r.user_id), 2))
$$;

-- drop the rest of the bombs onto tiles you didn't open (for the reveal at the end)
create or replace function _mines_fill(r mines_rounds, have int[]) returns int[]
language sql volatile as $$
  select have || coalesce(array(
    select t from generate_series(0, 24) t
     where not (t = any(r.revealed)) and not (t = any(have))
     order by random() limit greatest(0, r.mines - cardinality(have))), '{}')
$$;

create or replace function _mines_view(r mines_rounds, bal numeric default null) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', r.id, 'bet', r.bet, 'mines', r.mines, 'revealed', r.revealed, 'status', r.status,
    'mult', _mines_mult(r.mines, cardinality(r.revealed)),
    'next_mult', case when cardinality(r.revealed) < 25 - r.mines then _mines_mult(r.mines, cardinality(r.revealed) + 1) end,
    'cashout', case when r.status = 'live' and cardinality(r.revealed) > 0 then _mines_payout(r) end,
    'payout', r.payout,
    'bombs', case when r.status <> 'live' then r.bombs end,
    'balance', bal)
$$;
revoke execute on function _mines_view(mines_rounds, numeric) from public, anon, authenticated;
revoke execute on function _mines_payout(mines_rounds) from public, anon, authenticated;
revoke execute on function _mines_fill(mines_rounds, int[]) from public, anon, authenticated;

create or replace function mines_start(p_bet numeric, p_mines int) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r mines_rounds;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from mines_rounds where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current Mines round first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 24 then raise exception 'Pick 1 to 24 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

create or replace function _mines_cash(r mines_rounds) returns json
language plpgsql security definer set search_path = public as $$
declare pay numeric := _mines_payout(r); bal numeric;
begin
  update mines_rounds set status = 'cashed', payout = pay, bombs = _mines_fill(r, '{}') where id = r.id returning * into r;
  update profiles set balance = balance + pay where id = r.user_id returning balance into bal;
  return _mines_view(r, bal);
end $$;
revoke execute on function _mines_cash(mines_rounds) from public, anon, authenticated;

create or replace function mines_pick(p_id uuid, p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare r mines_rounds; k int; chance numeric; bal numeric;
begin
  select * into r from mines_rounds where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if r.status <> 'live' then raise exception 'Round is over'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Bad tile'; end if;
  if p_tile = any(r.revealed) then return _mines_view(r); end if;

  k := cardinality(r.revealed);
  chance := r.mines::numeric / (25 - k);                   -- fair odds of a bomb under this tile
  if _bad_luck_now(auth.uid()) then chance := 1;           -- bad luck: always a bomb
  else
    if _rush_now() then chance := chance * 0.5; end if;    -- rush hour: half the bombs
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := chance * 0.5; end if;
  end if;

  if random() < chance then
    update mines_rounds set status = 'boom', payout = 0, bombs = _mines_fill(r, array[p_tile]) where id = r.id returning * into r;
    select balance into bal from profiles where id = auth.uid();
    return _mines_view(r, bal);
  end if;

  update mines_rounds set revealed = revealed || p_tile where id = r.id returning * into r;
  -- every safe tile found, or max win reached: cash out automatically
  if cardinality(r.revealed) >= 25 - r.mines or _mines_payout(r) >= r.bet + 5000000 then
    return _mines_cash(r);
  end if;
  return _mines_view(r);
end $$;

create or replace function mines_cashout(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare r mines_rounds;
begin
  select * into r from mines_rounds where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if r.status <> 'live' then raise exception 'Round is over'; end if;
  if cardinality(r.revealed) = 0 then raise exception 'Open at least one tile first'; end if;
  return _mines_cash(r);
end $$;

create or replace function mines_current() returns json
language plpgsql security definer set search_path = public as $$
declare r mines_rounds;
begin
  select * into r from mines_rounds where user_id = auth.uid() and status = 'live' order by created_at desc limit 1;
  if not found then return null; end if;
  return _mines_view(r);
end $$;

-- refill can't be used while a Mines round is open
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  bal numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;

  perform ride_cleanup();
  update crash_rounds set status = 'crashed'
   where user_id = me and status = 'live'
     and extract(epoch from clock_timestamp() - started_at) >= ln(crash_point) / 0.09;

  if exists (select 1 from crash_rounds where user_id = me and status = 'live') then
    raise exception 'Your Rocket round is still flying. Cash out or let it crash first.';
  end if;
  if exists (select 1 from ride_rounds where user_id = me and status = 'live') then
    raise exception 'Stop your Ride round first.';
  end if;
  if exists (select 1 from bj_hands where user_id = me and status = 'live') then
    raise exception 'Finish your Blackjack hand first (it''s waiting in the Blackjack tab).';
  end if;
  if exists (select 1 from mines_rounds where user_id = me and status = 'live') then
    raise exception 'Cash out your Mines round first.';
  end if;

  select balance into bal from profiles where id = me;
  if bal >= 10 then raise exception 'Refill only works under 10 coins (you have %)', round(bal, 2); end if;
  update profiles set balance = 500 where id = me returning balance into bal;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';

-- Jambling: Mines high risk high reward. Run once in Supabase > SQL Editor (after mines.sql).
-- Every tap is 40% more likely to be a bomb, and the multiplier grows to match (house edge still 3%).

-- chance the next tap is a bomb, with k tiles already open
create or replace function _mines_chance(m int, k int) returns numeric
language sql immutable as $$
  select least(0.96, 1.4 * m / (25 - k)::numeric)
$$;

create or replace function _mines_mult(m int, k int) returns numeric
language sql immutable as $$
  select case when k <= 0 then 1::numeric
    else round(floor(0.97 * exp(coalesce((select sum(-ln(1 - _mines_chance(m, i))) from generate_series(0, k - 1) i), 0)) * 100) / 100, 2) end
$$;

create or replace function mines_pick(p_id uuid, p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare r mines_rounds; chance numeric; bal numeric;
begin
  select * into r from mines_rounds where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if r.status <> 'live' then raise exception 'Round is over'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Bad tile'; end if;
  if p_tile = any(r.revealed) then return _mines_view(r); end if;

  chance := _mines_chance(r.mines, cardinality(r.revealed));
  if _bad_luck_now(auth.uid()) then chance := 1;           -- bad luck: always a bomb
  else
    if _rush_now() then chance := chance * 0.5; end if;    -- rush hour: half the risk
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := chance * 0.5; end if;
  end if;

  if random() < chance then
    update mines_rounds set status = 'boom', payout = 0, bombs = _mines_fill(r, array[p_tile]) where id = r.id returning * into r;
    select balance into bal from profiles where id = auth.uid();
    return _mines_view(r, bal);
  end if;

  update mines_rounds set revealed = revealed || p_tile where id = r.id returning * into r;
  if cardinality(r.revealed) >= 25 - r.mines or _mines_payout(r) >= r.bet + 5000000 then
    return _mines_cash(r);
  end if;
  return _mines_view(r);
end $$;

notify pgrst, 'reload schema';

-- Jambling: Mines max win 20m. Run once in Supabase > SQL Editor (after mines.sql and mines2.sql).

create or replace function _mines_payout(r mines_rounds) returns numeric
language sql stable security definer set search_path = public as $$
  select least(r.bet + 20000000,
               round(r.bet + r.bet * (_mines_mult(r.mines, cardinality(r.revealed)) - 1) * _luck(r.user_id), 2))
$$;
revoke execute on function _mines_payout(mines_rounds) from public, anon, authenticated;

create or replace function mines_pick(p_id uuid, p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare r mines_rounds; chance numeric; bal numeric;
begin
  select * into r from mines_rounds where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if r.status <> 'live' then raise exception 'Round is over'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Bad tile'; end if;
  if p_tile = any(r.revealed) then return _mines_view(r); end if;

  chance := _mines_chance(r.mines, cardinality(r.revealed));
  if _bad_luck_now(auth.uid()) then chance := 1;           -- bad luck: always a bomb
  else
    if _rush_now() then chance := chance * 0.5; end if;    -- rush hour: half the risk
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := chance * 0.5; end if;
  end if;

  if random() < chance then
    update mines_rounds set status = 'boom', payout = 0, bombs = _mines_fill(r, array[p_tile]) where id = r.id returning * into r;
    select balance into bal from profiles where id = auth.uid();
    return _mines_view(r, bal);
  end if;

  update mines_rounds set revealed = revealed || p_tile where id = r.id returning * into r;
  if cardinality(r.revealed) >= 25 - r.mines or _mines_payout(r) >= r.bet + 20000000 then
    return _mines_cash(r);
  end if;
  return _mines_view(r);
end $$;

notify pgrst, 'reload schema';
