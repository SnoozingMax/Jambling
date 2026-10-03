-- Jambling: Supabase setup
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- All game logic runs here so players can't cheat from the browser.

-- ---------- Tables ----------
create table if not exists profiles (
  id uuid primary key references auth.users on delete cascade,
  username text not null,
  balance numeric not null default 1000,
  created_at timestamptz not null default now()
);

create table if not exists crash_rounds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  crash_point numeric not null,
  started_at timestamptz not null default clock_timestamp(),
  status text not null default 'live',   -- live | cashed | crashed
  cashout numeric
);

alter table profiles enable row level security;
alter table crash_rounds enable row level security;

-- Signed-in users can read profiles (for the leaderboard). Nobody can write directly.
drop policy if exists "profiles readable" on profiles;
create policy "profiles readable" on profiles for select to authenticated using (true);
-- crash_rounds has no policies: only the functions below can touch it.

-- ---------- New user -> profile with 1000 coins ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1)));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function handle_new_user();

-- ---------- Coin flip ----------
create or replace function flip_coin(p_bet numeric, p_pick text) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  res text;
  won boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  res := case when random() < 0.5 then 'heads' else 'tails' end;
  won := res = p_pick;

  update profiles
     set balance = balance + case when won then p_bet else -p_bet end
   where id = auth.uid()
  returning balance into bal;

  return json_build_object('result', res, 'won', won, 'balance', bal);
end $$;

-- ---------- Crash (rocket graph) ----------
-- Multiplier grows as exp(0.09 * seconds). Keep 0.09 in sync with K in index.html.

create or replace function crash_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  cp numeric;
  rid uuid;
  r float8;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;

  -- abandoned rounds are forfeited
  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  -- secret crash point, 3% house edge, capped at 1000x
  r := random();
  cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;

  return json_build_object('round_id', rid, 'balance', bal);
end $$;

create or replace function crash_status(p_round uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd crash_rounds;
  m numeric;
begin
  select * into rd from crash_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;

  if rd.status = 'crashed' then
    return json_build_object('crashed', true, 'crash_point', rd.crash_point);
  end if;

  m := exp(0.09 * extract(epoch from clock_timestamp() - rd.started_at));
  if m >= rd.crash_point then
    if rd.status = 'live' then
      update crash_rounds set status = 'crashed' where id = rd.id;
    end if;
    -- cashed rounds stay 'cashed'; the crash point is only revealed once the ghost reaches it
    return json_build_object('crashed', true, 'crash_point', rd.crash_point);
  end if;

  return json_build_object('crashed', false);
end $$;

create or replace function crash_cashout(p_round uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd crash_rounds;
  m numeric;
  payout numeric;
  bal numeric;
begin
  select * into rd from crash_rounds where id = p_round and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if rd.status <> 'live' then raise exception 'Round over'; end if;

  m := floor(exp(0.09 * extract(epoch from clock_timestamp() - rd.started_at)) * 100) / 100;

  if m >= rd.crash_point then
    update crash_rounds set status = 'crashed' where id = rd.id;
    select balance into bal from profiles where id = auth.uid();
    return json_build_object('won', false, 'crash_point', rd.crash_point, 'balance', bal);
  end if;

  payout := round(rd.bet * m, 2);
  update crash_rounds set status = 'cashed', cashout = m where id = rd.id;
  update profiles set balance = balance + payout where id = auth.uid() returning balance into bal;

  return json_build_object('won', true, 'multiplier', m, 'payout', payout, 'balance', bal, 'crash_point', rd.crash_point);
end $$;

-- ---------- Refill when broke ----------
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  update profiles set balance = 1000 where id = auth.uid() and balance < 10 returning balance into bal;
  if bal is null then raise exception 'Refill only works under 10 coins'; end if;
  return json_build_object('balance', bal);
end $$;

-- Jambling: daily reward, resets at midnight Pacific time.
-- Run this once in Supabase > SQL Editor (safe to run again).
alter table profiles add column if not exists last_daily timestamptz;

-- when the next daily unlocks (null = available now)
create or replace function daily_next() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  last timestamptz;
begin
  select last_daily into last from profiles where id = auth.uid();
  if last is null or (last at time zone 'America/Los_Angeles')::date < (now() at time zone 'America/Los_Angeles')::date then
    return null;
  end if;
  return (date_trunc('day', now() at time zone 'America/Los_Angeles') + interval '1 day') at time zone 'America/Los_Angeles';
end $$;

create or replace function claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  perform 1 from profiles where id = auth.uid() for update;
  if daily_next() is not null then raise exception 'Already claimed today'; end if;
  update profiles set balance = balance + 250, last_daily = now()
   where id = auth.uid() returning balance into bal;
  return json_build_object('balance', bal, 'next', daily_next());
end $$;

-- ========== Ride ==========

create table if not exists chart_rounds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  prices float8[] not null,
  started_at timestamptz not null default clock_timestamp(),
  status text not null default 'live',  -- live | done
  holding boolean not null default false,
  hold_step int not null default 0,
  mult float8 not null default 1,
  payout numeric
);
alter table chart_rounds enable row level security;  -- no policies: only functions touch it

-- bring mult up to date for the current step (internal)
create or replace function _chart_settle(p_id uuid) returns chart_rounds
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
  k int;
begin
  select * into rd from chart_rounds where id = p_id for update;
  if rd.status <> 'live' then return rd; end if;
  k := least(150, floor(extract(epoch from clock_timestamp() - rd.started_at) / 0.2)::int);
  if rd.holding and k > rd.hold_step then
    rd.mult := least(20, rd.mult * rd.prices[k + 1] / rd.prices[rd.hold_step + 1]);
  end if;
  rd.hold_step := k;
  update chart_rounds set mult = rd.mult, hold_step = k where id = rd.id;
  return rd;
end $$;

-- settle and pay out (internal)
create or replace function _chart_finish(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
  pay numeric;
  bal numeric;
begin
  rd := _chart_settle(p_id);
  if rd.status <> 'live' then
    select balance into bal from profiles where id = rd.user_id;
    return json_build_object('status', 'done', 'payout', rd.payout, 'mult', rd.mult, 'balance', bal);
  end if;
  pay := round((rd.bet * rd.mult)::numeric, 2);
  update chart_rounds set status = 'done', payout = pay, holding = false where id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('status', 'done', 'payout', pay, 'mult', rd.mult, 'balance', bal);
end $$;

revoke execute on function _chart_settle(uuid) from public, anon, authenticated;
revoke execute on function _chart_finish(uuid) from public, anon, authenticated;

create or replace function chart_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rid uuid;
  old uuid;
  arr float8[] := array[100.0];
  p float8 := 100;
  v float8 := 0;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;

  -- finish any round left running (paid out at its result)
  for old in select id from chart_rounds where user_id = auth.uid() and status = 'live' loop
    perform _chart_finish(old);
  end loop;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  -- trending random walk: momentum makes swings you can read and react to
  for i in 1..150 loop
    v := 0.9 * v + (random() - 0.5) * 0.02;
    p := p * exp(v - 0.0004);
    arr := arr || p;
  end loop;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into chart_rounds (user_id, bet, prices) values (auth.uid(), p_bet, arr) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal, 'start', 100);
end $$;

-- new prices since index p_from (0-based), plus current value
create or replace function chart_poll(p_round uuid, p_from int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
  fin json;
begin
  perform 1 from chart_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  rd := _chart_settle(p_round);
  if rd.status = 'live' and rd.hold_step >= 150 then
    fin := _chart_finish(p_round);
    return json_build_object('prices', rd.prices[p_from + 1 : 151], 'k', 150, 'mult', rd.mult,
      'status', 'done', 'payout', fin->'payout', 'balance', fin->'balance');
  end if;
  return json_build_object('prices', rd.prices[p_from + 1 : rd.hold_step + 1], 'k', rd.hold_step,
    'mult', rd.mult, 'status', rd.status);
end $$;

create or replace function chart_hold(p_round uuid, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
begin
  perform 1 from chart_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  rd := _chart_settle(p_round);
  if rd.status <> 'live' then return json_build_object('status', rd.status, 'mult', rd.mult); end if;
  if rd.hold_step >= 150 then return _chart_finish(p_round); end if;
  update chart_rounds set holding = p_on where id = p_round;
  return json_build_object('status', 'live', 'mult', rd.mult, 'k', rd.hold_step);
end $$;

create or replace function chart_cashout(p_round uuid) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform 1 from chart_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  return _chart_finish(p_round);
end $$;
