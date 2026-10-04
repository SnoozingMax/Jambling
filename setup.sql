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
create table if not exists ride_rounds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  seed bigint not null,
  started_at timestamptz not null default clock_timestamp(),
  status text not null default 'live',
  holds int[] not null default '{}',   -- start,end,start,end,... (steps of 100ms)
  holding boolean not null default false,
  last_step int not null default 0,
  mult float8,
  payout numeric
);
alter table ride_rounds enable row level security;

-- the chart: momentum random walk. MUST match ridePath() in index.html
create or replace function _ride_path(p_seed bigint, n int) returns float8[]
language plpgsql immutable as $$
declare
  s bigint := p_seed;
  v float8 := 0;
  p float8 := 100;
  heat float8 := 1;
  vol float8;
  u1 float8; u2 float8; u3 float8;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * least(3, 1 + i::float8 / 600);          -- gets riskier over time
    if u3 > 0.995 then                                    -- pump or dump
      v := v + case when u2 > 0.5 then 0.03 else -0.03 end;
    end if;
    v := 0.88 * v + (u1 - 0.5) * 0.009 * vol - 0.002 * ln(p / 100);
    p := p * exp(v + (u2 - 0.5) * 0.035 * vol);
    arr := arr || p;
  end loop;
  return arr;
end $$;

create or replace function _ride_k(rd ride_rounds) returns int
language sql stable as $$
  select floor(extract(epoch from clock_timestamp() - rd.started_at) / 0.1)::int
$$;

-- clamp a reported step to a fair window around real time
create or replace function _ride_clamp(rd ride_rounds, p_step int) returns int
language plpgsql stable as $$
declare
  k int := _ride_k(rd);
begin
  return greatest(least(coalesce(p_step, k), k + 2), k - 15, rd.last_step);
end $$;

create or replace function ride_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rid uuid;
  sd bigint := floor(random() * 2147483645)::bigint + 1;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;

  -- a round left open (tab closed) is forfeited
  update ride_rounds set status = 'abandoned', payout = 0 where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into ride_rounds (user_id, bet, seed) values (auth.uid(), p_bet, sd) returning id into rid;
  return json_build_object('round_id', rid, 'seed', sd, 'balance', bal);
end $$;

create or replace function ride_hold(p_round uuid, p_on boolean, p_step int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd ride_rounds;
  a int;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if rd.status <> 'live' or rd.holding = p_on then return json_build_object('ok', true); end if;
  a := _ride_clamp(rd, p_step);
  update ride_rounds set holds = holds || a, holding = p_on, last_step = a where id = rd.id;
  return json_build_object('ok', true, 'step', a);
end $$;

create or replace function ride_stop(p_round uuid, p_step int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd ride_rounds;
  a int;
  h int[];
  path float8[];
  m float8 := 1;
  pay numeric;
  bal numeric;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if rd.status <> 'live' then raise exception 'Round over'; end if;

  a := _ride_clamp(rd, p_step);
  h := rd.holds;
  if rd.holding then h := h || a; end if;

  path := _ride_path(rd.seed, a);
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * path[h[2*i] + 1] / path[h[2*i - 1] + 1];
  end loop;
  m := least(m, 25);

  pay := round((rd.bet * m)::numeric, 2);
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  update profiles set balance = balance + pay where id = auth.uid() returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a);
end $$;

