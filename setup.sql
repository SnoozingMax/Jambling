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
alter table profiles add column if not exists rebirths int not null default 0;

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
alter table ride_rounds add column if not exists boost_steps int not null default 0;
alter table profiles add column if not exists boost_until timestamptz;

-- the chart: momentum random walk. MUST match ridePath() in index.html
drop function if exists _ride_path(bigint, int);
create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0) returns float8[]
language plpgsql immutable as $$
declare
  s bigint := p_seed;
  v float8 := 0;
  p float8 := 100;
  heat float8 := 1;
  vol float8;
  u1 float8; u2 float8; u3 float8;
  ev_left int := 0; ev_dir float8 := 0; d int := 0;
  size float8 := 0; w float8 := 1; x float8; drift float8;
  k int; ev int;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_boost then                                  -- admin boost: nonstop pump, no dumps
      p := p * exp(0.006 + (u2 - 0.5) * 0.02);
      ev_left := 0; v := 0;
      arr := arr || p;
      continue;
    end if;
    if ev_left = 0 and u3 > 0.99 then
      if u2 < 0.45 then                                   -- hidden pump: +65% to +170% over 3-7s, swells in the middle
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53));
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := 0.15 + 0.25 * (u1 * 53 - floor(u1 * 53));
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1;
      end if;
      ev_left := ev_left - 1;
    end if;
    if ev >= 0 then                                       -- normal chop keeps going during pumps, so they're hard to spot
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
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

-- bump this whenever the chart math changes; must match RIDE_VERSION in index.html
create or replace function ride_version() returns int language sql immutable as $$ select 28 $$;

-- pay out a round at step a (internal: never callable from the browser)
create or replace function _ride_finish(p_id uuid, a int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd ride_rounds;
  h int[];
  path float8[];
  m float8 := 1;
  pay numeric;
  bal numeric;
begin
  select * into rd from ride_rounds where id = p_id for update;
  if rd.status <> 'live' then return json_build_object('payout', rd.payout); end if;
  a := greatest(a, rd.last_step);
  h := rd.holds;
  if rd.holding then h := h || a; end if;

  path := _ride_path(rd.seed, a, rd.boost_steps);
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  m := least(m, 25);

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;
revoke execute on function _ride_finish(uuid, int) from public, anon, authenticated;

-- settle rounds left open (tab closed): stops the bet instead of losing it.
-- if you were holding, the hold counts until you left (max 5s after your last action).
create or replace function ride_cleanup() returns json
language plpgsql security definer set search_path = public as $$
declare
  rd ride_rounds;
  out json := null;
begin
  for rd in select * from ride_rounds where user_id = auth.uid() and status = 'live' loop
    out := _ride_finish(rd.id, case when rd.holding then least(_ride_k(rd), rd.last_step + 50) else rd.last_step end);
  end loop;
  return out;
end $$;

drop function if exists ride_start(numeric);
create or replace function ride_start(p_bet numeric, p_ver int) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rid uuid;
  bs int;
  sd bigint := floor(random() * 2147483645)::bigint + 1;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_ver is distinct from ride_version() then raise exception 'Ride was updated. Refresh the page.'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 10000 then raise exception 'Max Ride bet is 10,000'; end if;

  perform ride_cleanup();

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  select greatest(0, floor(extract(epoch from (boost_until - clock_timestamp())) / 0.1))::int into bs
    from profiles where id = auth.uid() and boost_until > clock_timestamp();
  insert into ride_rounds (user_id, bet, seed, boost_steps) values (auth.uid(), p_bet, sd, coalesce(bs, 0)) returning id into rid;
  return json_build_object('round_id', rid, 'seed', sd, 'balance', bal, 'boost_steps', coalesce(bs, 0));
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
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  if rd.status <> 'live' then raise exception 'Round over'; end if;
  return _ride_finish(rd.id, _ride_clamp(rd, p_step));
end $$;

notify pgrst, 'reload schema';

-- clean up the previous Ride version
drop function if exists chart_poll(uuid, int);
drop function if exists chart_hold(uuid, boolean, int);
drop function if exists chart_cashout(uuid, int);
drop function if exists chart_start(numeric);
drop function if exists _chart_finish(uuid, int);
drop function if exists _chart_settle(uuid, int);
drop function if exists _chart_k(chart_rounds);
drop function if exists chart_poll(uuid, int);
drop function if exists chart_hold(uuid, boolean);
drop function if exists chart_cashout(uuid);
drop function if exists _chart_finish(uuid);
drop function if exists _chart_settle(uuid);

-- ========== Gifting ==========
create table if not exists gifts (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references profiles(id) on delete cascade,
  to_id uuid not null references profiles(id) on delete cascade,
  amount numeric not null,
  created_at timestamptz not null default now(),
  seen boolean not null default false
);
alter table gifts enable row level security;  -- only the functions below touch it

create or replace function gift_coins(p_to text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  bal numeric;
  them_name text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  -- lock both rows in a fixed order so two gifts at once can't deadlock
  perform 1 from profiles where id in (me, them) order by id for update;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  update profiles set balance = balance + p_amount where id = them;
  insert into gifts (from_id, to_id, amount) values (me, them, p_amount);
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount);
end $$;

-- gifts you received that you haven't seen yet (marks them seen)
create or replace function my_new_gifts() returns json
language plpgsql security definer set search_path = public as $$
declare
  out json;
begin
  select coalesce(json_agg(json_build_object('from', p.username, 'amount', g.amount) order by g.created_at), '[]')
    into out
    from gifts g join profiles p on p.id = g.from_id
   where g.to_id = auth.uid() and not g.seen;
  update gifts set seen = true where to_id = auth.uid() and not seen;
  return out;
end $$;

-- ========== Rebirths ==========
alter table profiles add column if not exists rebirths int not null default 0;

create or replace function _luck(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select 1 + 0.1 * coalesce((select rebirths from profiles where id = p_uid), 0)
$$;

create or replace function rebirth() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rb int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < 100000 then raise exception 'You need 100,000 coins to rebirth'; end if;
  update profiles set balance = 1000, rebirths = rebirths + 1 where id = auth.uid()
    returning balance, rebirths into bal, rb;
  return json_build_object('balance', bal, 'rebirths', rb);
end $$;

-- coin flip: wins pay bet x luck
create or replace function flip_coin(p_bet numeric, p_pick text) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  res text;
  won boolean;
  delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  res := case when random() < 0.5 then 'heads' else 'tails' end;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

-- rocket: profit x luck
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

  payout := round(rd.bet + rd.bet * (m - 1) * _luck(auth.uid()), 2);
  update crash_rounds set status = 'cashed', cashout = m where id = rd.id;
  update profiles set balance = balance + payout where id = auth.uid() returning balance into bal;

  return json_build_object('won', true, 'multiplier', m, 'payout', payout, 'balance', bal, 'crash_point', rd.crash_point);
end $$;

notify pgrst, 'reload schema';

-- ========== Admin ==========
create table if not exists admins (user_id uuid primary key references profiles(id) on delete cascade);
alter table admins enable row level security;   -- no policies: only functions read it
insert into admins select id from profiles where username = 'max' on conflict do nothing;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

-- give a player 5 minutes of nonstop pump in Ride, for a price in coins
create or replace function admin_boost(p_user text, p_cost numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; bal numeric; until timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_cost := round(coalesce(p_cost, 0), 2);
  if p_cost < 0 then raise exception 'Invalid price'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;

  select balance into bal from profiles where id = them for update;
  if bal < p_cost then raise exception '% only has % coins', them_name, bal; end if;
  update profiles
     set balance = balance - p_cost,
         boost_until = greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '5 minutes'
   where id = them returning balance, boost_until into bal, until;
  return json_build_object('user', them_name, 'balance', bal, 'until', until);
end $$;

notify pgrst, 'reload schema';
