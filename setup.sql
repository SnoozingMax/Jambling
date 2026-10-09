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
alter table ride_rounds add column if not exists bad_steps int not null default 0;
alter table ride_rounds add column if not exists rush_steps int not null default 0;
create table if not exists site_state (id int primary key default 1 check (id = 1), rush_until timestamptz);
insert into site_state (id) values (1) on conflict do nothing;
alter table profiles add column if not exists badluck_until timestamptz;
alter table profiles add column if not exists boost_until timestamptz;

-- the chart: momentum random walk. MUST match ridePath() in index.html
drop function if exists _ride_path(bigint, int);
drop function if exists _ride_path(bigint, int, int);
drop function if exists _ride_path(bigint, int, int, int);
create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0) returns float8[]
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
  cut int := -1; rug int := 0; base float8 := 100;
  k int; ev int; done boolean;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_bad then                                    -- bad luck: little pump, then rug pull, forever
      k := (i - 1) % 10;
      if k < 6 then p := p * exp(0.01 + (u2 - 0.5) * 0.006);
      elsif k < 9 then p := p * exp(ln(0.6) / 3);
      end if;
      ev_left := 0; rug := 0; v := 0;
      p := least(greatest(p, 1e-200), 1e200);
      arr := arr || p;
      continue;
    end if;
    if i <= p_boost then                                  -- admin boost: fast nonstop pump (~+22%/s), no dumps
      p := least(p * exp(0.02 + (u2 - 0.5) * 0.02), 1e200);
      ev_left := 0; rug := 0; v := 0;
      arr := arr || p;
      continue;
    end if;
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.98 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.8 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53));
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.15 then
          cut := 3 + floor((u1 * 331 - floor(u1 * 331)) * (d - 3))::int;
        else
          cut := -1;
        end if;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := 0.15 + 0.25 * (u1 * 53 - floor(u1 * 53));
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0; done := false;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        if k = cut then
          ev_left := 0; rug := 3;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: crash to half of where the pump started
      p := p * exp(ln(base * 0.5 / p) / rug);
      rug := rug - 1; v := 0; done := true;
    end if;
    if not done then                                      -- normal chop keeps going during pumps
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
    p := least(greatest(p, 1e-200), 1e200);                -- never overflow
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
create or replace function ride_version() returns int language sql immutable as $$ select 34 $$;

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

  path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 500000);                          -- max win 500k per round (RIDE_MAX_WIN in index.html)
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
  bad int;
  rush int;
  sd bigint := floor(random() * 2147483645)::bigint + 1;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_ver is distinct from ride_version() then raise exception 'Ride was updated. Refresh the page.'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;

  perform ride_cleanup();

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  select greatest(0, floor(extract(epoch from (boost_until - clock_timestamp())) / 0.1))::int into bs
    from profiles where id = auth.uid() and boost_until > clock_timestamp();
  select greatest(0, floor(extract(epoch from (badluck_until - clock_timestamp())) / 0.1))::int into bad
    from profiles where id = auth.uid() and badluck_until > clock_timestamp();
  select greatest(0, floor(extract(epoch from (rush_until - clock_timestamp())) / 0.1))::int into rush
    from site_state where id = 1 and rush_until > clock_timestamp();
  insert into ride_rounds (user_id, bet, seed, boost_steps, bad_steps, rush_steps)
    values (auth.uid(), p_bet, sd, coalesce(bs, 0), coalesce(bad, 0), coalesce(rush, 0)) returning id into rid;
  return json_build_object('round_id', rid, 'seed', sd, 'balance', bal, 'boost_steps', coalesce(bs, 0), 'bad_steps', coalesce(bad, 0), 'rush_steps', coalesce(rush, 0));
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

-- give a player 5 minutes of nonstop pump in Ride (free)
drop function if exists admin_boost(text, numeric);
create or replace function admin_boost(p_user text) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; until timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles
     set boost_until = greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '5 minutes'
   where id = them returning boost_until into until;
  return json_build_object('user', them_name, 'until', until);
end $$;

-- take coins away from a player (never below 0)
create or replace function admin_take(p_user text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; bal numeric; took numeric;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 then raise exception 'Enter an amount'; end if;
  select id, username, balance into them, them_name, bal from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1 for update;
  if them is null then raise exception 'No player named %', p_user; end if;
  took := least(p_amount, bal);
  update profiles set balance = balance - took where id = them returning balance into bal;
  return json_build_object('user', them_name, 'took', took, 'balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Blackjack ==========
drop function if exists claim_refill();

create table if not exists bj_hands (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  deck int[] not null,
  player int[] not null default '{}',
  dealer int[] not null default '{}',
  status text not null default 'live',   -- live | done
  result text,
  payout numeric,
  created_at timestamptz not null default now()
);
alter table bj_hands enable row level security;   -- no policies: only functions touch it
alter table profiles add column if not exists badluck_until timestamptz;
create table if not exists site_state (id int primary key default 1 check (id = 1), rush_until timestamptz);
insert into site_state (id) values (1) on conflict do nothing;
-- your card values: an ace stays null until you pick 1 or 11 (then it's locked)
alter table bj_hands add column if not exists pvals int[];
-- hands from before this update: refund and close
update profiles p set balance = p.balance + h.bet from bj_hands h where h.user_id = p.id and h.status = 'live' and h.pvals is null;
update bj_hands set status = 'done', result = 'void', payout = bet where status = 'live' and pvals is null;

-- card c: rank = c % 13 (0 = A, 1..9 = 2..10, 10..12 = J Q K)
create or replace function _bj_total(cards int[]) returns int
language plpgsql immutable as $$
declare
  t int := 0; aces int := 0; r int;
begin
  foreach r in array coalesce(cards, '{}') loop
    r := r % 13;
    if r = 0 then aces := aces + 1; t := t + 11;
    elsif r >= 9 then t := t + 10;
    else t := t + r + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

create or replace function _bj_val(c int) returns int language sql immutable as $$
  select case when c % 13 = 0 then null when c % 13 >= 9 then 10 else c % 13 + 1 end
$$;
create or replace function _bj_sum(v int[]) returns int language sql immutable as $$
  select coalesce(sum(x), 0)::int from unnest(v) x
$$;
create or replace function _bj_pending(v int[]) returns int[] language sql immutable as $$
  select coalesce(array_agg(i order by i), '{}') from generate_subscripts(v, 1) i where v[i] is null
$$;

-- what the browser is allowed to see
create or replace function _bj_view(h bj_hands) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  bal numeric;
  dview int[];
  pend int[] := _bj_pending(h.pvals);
begin
  select balance into bal from profiles where id = h.user_id;
  dview := case when h.status = 'live' then h.dealer[1:1] else h.dealer end;
  return json_build_object(
    'id', h.id, 'bet', h.bet, 'status', h.status, 'result', h.result, 'payout', h.payout,
    'player', h.player, 'pvals', h.pvals, 'pending', pend,
    'dealer', dview, 'hidden', h.status = 'live',
    'player_total', _bj_sum(h.pvals), 'dealer_total', _bj_total(dview),
    'can_double', h.status = 'live' and array_length(h.player, 1) = 2 and bal >= h.bet and cardinality(pend) = 0,
    'balance', bal);
end $$;

-- dealer plays, hand is settled and paid (internal)
create or replace function _bj_settle(p_id uuid, p_result text default null) returns bj_hands
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands; pt int; dt int; res text; pay numeric := 0; luck numeric;
begin
  select * into h from bj_hands where id = p_id for update;
  if h.status <> 'live' then return h; end if;
  pt := _bj_sum(h.pvals);
  res := p_result;
  if res is null then
    if pt > 21 then res := 'bust';
    else
      while _bj_total(h.dealer) < 17 loop h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:]; end loop;
      dt := _bj_total(h.dealer);
      res := case when dt > 21 or pt > dt then 'win' when pt = dt then 'push' else 'lose' end;
    end if;
  end if;
  luck := 1 + 0.1 * coalesce((select rebirths from profiles where id = h.user_id), 0);
  pay := case res
    when 'blackjack' then round(h.bet + h.bet * 1.5 * luck, 2)
    when 'win'       then round(h.bet + h.bet * luck, 2)
    when 'push'      then h.bet
    else 0 end;
  update bj_hands set dealer = h.dealer, deck = h.deck, status = 'done', result = res, payout = pay where id = h.id
    returning * into h;
  update profiles set balance = balance + pay where id = h.user_id;
  return h;
end $$;
revoke execute on function _bj_settle(uuid, text) from public, anon, authenticated;
revoke execute on function _bj_view(bj_hands) from public, anon, authenticated;

-- after any change: bust, or auto-stand on 21 (only once every ace is chosen)
create or replace function _bj_check(p_id uuid) returns bj_hands
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id;
  if h.status <> 'live' or cardinality(_bj_pending(h.pvals)) > 0 then return h; end if;
  if _bj_sum(h.pvals) > 21 then return _bj_settle(h.id, 'bust'); end if;
  if _bj_sum(h.pvals) = 21 then return _bj_settle(h.id); end if;
  return h;
end $$;
revoke execute on function _bj_check(uuid) from public, anon, authenticated;

create or replace function bj_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric; h bj_hands; d int[]; dt int; is_bj boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current hand first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid();

  select array_agg(c order by random()) into d from generate_series(0, 51) c;
  -- bad luck: you get 16, dealer gets 20, and the next cards are all 10s
  if (select badluck_until > clock_timestamp() from profiles where id = auth.uid()) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            six int := (select c from unnest(d) c where c % 13 = 5 limit 1);
            picked int[];
    begin
      picked := array[tens[1], tens[2], six, tens[3]];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by (c % 13 >= 9) desc, random());
    end;
  elsif (select rush_until > clock_timestamp() from site_state where id = 1) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            good int := (select c from unnest(d) c where c % 13 in (0, 8) or c % 13 >= 9 limit 1 offset 1);
            weak int := (select c from unnest(d) c where c % 13 in (3, 4, 5) limit 1);
            picked int[];
    begin
      if good = tens[1] then good := tens[2]; end if;
      picked := array[tens[1], weak, good];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by random());
      d := d[1:3] || d[4:];
    end;
  end if;
  insert into bj_hands (user_id, bet, deck, player, dealer, pvals)
    values (auth.uid(), p_bet, d[5:], array[d[1], d[3]], array[d[2], d[4]], array[_bj_val(d[1]), _bj_val(d[3])])
    returning * into h;

  is_bj := _bj_total(h.player) = 21;          -- ace + ten is always blackjack
  dt := _bj_total(h.dealer);
  if is_bj then
    update bj_hands set pvals = array[coalesce(pvals[1], 11), coalesce(pvals[2], 11)] where id = h.id;
    h := _bj_settle(h.id, case when dt = 21 then 'push' else 'blackjack' end);
  elsif dt = 21 then
    h := _bj_settle(h.id, 'lose');
  end if;
  return _bj_view(h);
end $$;

-- pick 1 or 11 for one of your aces (locked once picked)
create or replace function bj_ace(p_id uuid, p_idx int, p_val int) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if p_val not in (1, 11) then raise exception 'Ace must be 1 or 11'; end if;
  if p_idx is null or p_idx < 1 or p_idx > cardinality(h.player) or h.player[p_idx] % 13 <> 0 then raise exception 'That card isn''t an ace'; end if;
  if h.pvals[p_idx] is not null then raise exception 'That ace is already locked'; end if;
  h.pvals[p_idx] := p_val;
  update bj_hands set pvals = h.pvals where id = h.id;
  return _bj_view(_bj_check(h.id));
end $$;

create or replace function bj_hit(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if cardinality(_bj_pending(h.pvals)) > 0 then raise exception 'Pick 1 or 11 for your ace first'; end if;
  update bj_hands set player = player || deck[1], pvals = pvals || _bj_val(deck[1]), deck = deck[2:] where id = h.id;
  return _bj_view(_bj_check(h.id));
end $$;

create or replace function bj_stand(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid();
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if cardinality(_bj_pending(h.pvals)) > 0 then raise exception 'Pick 1 or 11 for your ace first'; end if;
  return _bj_view(_bj_settle(h.id));
end $$;

create or replace function bj_double(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands; bal numeric; c int; v int;
begin
  select * into h from bj_hands where id = p_id and user_id = auth.uid() for update;
  if not found or h.status <> 'live' then raise exception 'No hand in play'; end if;
  if array_length(h.player, 1) <> 2 then raise exception 'You can only double on your first two cards'; end if;
  if cardinality(_bj_pending(h.pvals)) > 0 then raise exception 'Pick 1 or 11 for your ace first'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < h.bet then raise exception 'Not enough coins to double'; end if;
  update profiles set balance = balance - h.bet where id = auth.uid();
  c := h.deck[1];
  v := coalesce(_bj_val(c), case when _bj_sum(h.pvals) + 11 <= 21 then 11 else 1 end);   -- an ace on a double picks the best value
  update bj_hands set bet = bet * 2, player = player || c, pvals = pvals || v, deck = deck[2:] where id = h.id;
  return _bj_view(_bj_settle(h.id, case when _bj_sum(h.pvals) + v > 21 then 'bust' end));
end $$;

-- resume a hand after closing the tab
create or replace function bj_current() returns json
language plpgsql security definer set search_path = public as $$
declare h bj_hands;
begin
  select * into h from bj_hands where user_id = auth.uid() and status = 'live' order by created_at desc limit 1;
  if not found then return null; end if;
  return _bj_view(h);
end $$;

notify pgrst, 'reload schema';

-- ========== Bans ==========
alter table profiles add column if not exists banned boolean not null default false;

-- a banned player's coins are frozen at 0, whatever any game or gift tries to do
create or replace function _keep_banned_broke() returns trigger
language plpgsql as $$
begin
  if new.banned then new.balance := 0; end if;
  return new;
end $$;
drop trigger if exists keep_banned_broke on profiles;
create trigger keep_banned_broke before update on profiles
for each row execute function _keep_banned_broke();

create or replace function admin_ban(p_user text, p_ban boolean) returns json
language plpgsql security definer set search_path = public, auth as $$
declare
  them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_ban and exists (select 1 from admins where user_id = them) then raise exception 'Can''t ban an admin'; end if;

  update profiles set banned = p_ban where id = them;
  -- block sign-in, and sign them out everywhere
  update auth.users set banned_until = case when p_ban then 'infinity'::timestamptz else null end where id = them;
  if p_ban then delete from auth.sessions where user_id = them; end if;
  return json_build_object('user', them_name, 'banned', p_ban);
end $$;


-- ========== Refill ==========

create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from crash_rounds where user_id = auth.uid() and status = 'live'
               and exp(0.09 * extract(epoch from clock_timestamp() - started_at)) < crash_point)
     or exists (select 1 from ride_rounds where user_id = auth.uid() and status = 'live')
     or exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current game before refilling';
  end if;
  update profiles set balance = 100 where id = auth.uid() and balance < 10 returning balance into bal;
  if bal is null then raise exception 'Refill only works under 10 coins'; end if;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Seasons ==========
-- ---------- seasons ----------
create table if not exists seasons (id serial primary key, ended_at timestamptz not null default now());
create table if not exists season_results (
  season_id int not null references seasons(id) on delete cascade,
  user_id uuid, username text not null, balance numeric not null, rebirths int not null, rank int not null
);
alter table seasons enable row level security;
alter table season_results enable row level security;
drop policy if exists "seasons readable" on seasons;
create policy "seasons readable" on seasons for select to authenticated using (true);
drop policy if exists "season results readable" on season_results;
create policy "season results readable" on season_results for select to authenticated using (true);

-- end the season: save everyone's final standing, then reset everyone
create or replace function admin_new_season() returns json
language plpgsql security definer set search_path = public as $$
declare sid int; n int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  insert into seasons default values returning id into sid;
  insert into season_results (season_id, user_id, username, balance, rebirths, rank)
    select sid, id, username, balance, rebirths, row_number() over (order by rebirths desc, balance desc)
      from profiles where not banned;
  get diagnostics n = row_count;
  -- end anything in progress
  update crash_rounds set status = 'crashed' where status = 'live';
  update ride_rounds set status = 'abandoned', payout = 0 where status = 'live';
  update bj_hands set status = 'done', result = 'void', payout = 0 where status = 'live';
  update profiles set balance = 1000, rebirths = 0, boost_until = null where true;
  return json_build_object('season', sid, 'players', n);
end $$;

-- ---------- admin: rename (login name changes too) ----------
create or replace function admin_rename(p_user text, p_new text) returns json
language plpgsql security definer set search_path = public, auth as $$
declare them uuid; old_name text; new_email text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_new := trim(p_new);
  if p_new !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'New name: 3-20 letters, numbers, or _'; end if;
  select id, username into them, old_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if exists (select 1 from profiles where lower(username) = lower(p_new) and id <> them) then raise exception 'That name is taken'; end if;
  new_email := lower(p_new) || '@users.jambling.app';
  update profiles set username = p_new where id = them;
  -- accounts made with username + passcode log in with this hidden email
  if (select email from auth.users where id = them) like '%@users.jambling.app' then
    if exists (select 1 from auth.users where email = new_email and id <> them) then raise exception 'That name is taken'; end if;
    update auth.users set email = new_email where id = them;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', new_email)
      where user_id = them and provider = 'email';
  end if;
  return json_build_object('old', old_name, 'new', p_new);
end $$;

-- ---------- admin: take rebirths ----------
create or replace function admin_take_rebirths(p_user text, p_n int) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; rb int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_n is null or p_n <= 0 then raise exception 'Enter how many'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set rebirths = greatest(0, rebirths - p_n) where id = them returning rebirths into rb;
  return json_build_object('user', them_name, 'rebirths', rb);
end $$;

notify pgrst, 'reload schema';

-- ========== Delete account ==========
create or replace function admin_delete(p_user text) returns json
language plpgsql security definer set search_path = public, auth as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if exists (select 1 from admins where user_id = them) then raise exception 'Can''t delete an admin'; end if;
  delete from auth.users where id = them;   -- removes their profile and games too
  return json_build_object('user', them_name);
end $$;
notify pgrst, 'reload schema';

-- ========== Notice + rename me ==========

create table if not exists site_notice (id int primary key default 1 check (id = 1), text text not null default '');
alter table site_notice enable row level security;
drop policy if exists "notice readable" on site_notice;
create policy "notice readable" on site_notice for select to anon, authenticated using (true);
insert into site_notice (id, text)
values (1, 'Change your username to your real name by Tuesday, Oct 13, or your account will be banned.')
on conflict (id) do update set text = excluded.text;

create or replace function admin_set_notice(p_text text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update site_notice set text = coalesce(trim(p_text), '') where id = 1;
  return json_build_object('text', coalesce(trim(p_text), ''));
end $$;

-- change your own name (your login name changes too)
create or replace function rename_me(p_new text) returns json
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); old_name text; new_email text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  p_new := trim(p_new);
  if p_new !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'Name: 3-20 letters, numbers, or _'; end if;
  select username into old_name from profiles where id = me;
  if exists (select 1 from profiles where lower(username) = lower(p_new) and id <> me) then raise exception 'That name is taken'; end if;
  new_email := lower(p_new) || '@users.jambling.app';
  if (select email from auth.users where id = me) like '%@users.jambling.app' then
    if exists (select 1 from auth.users where email = new_email and id <> me) then raise exception 'That name is taken'; end if;
    update auth.users set email = new_email where id = me;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', new_email)
      where user_id = me and provider = 'email';
  end if;
  update profiles set username = p_new where id = me;
  return json_build_object('old', old_name, 'new', p_new);
end $$;

notify pgrst, 'reload schema';

-- ========== 1v1 Blackjack ==========

create table if not exists pvp_matches (
  id uuid primary key default gen_random_uuid(),
  a uuid not null references profiles(id) on delete cascade,   -- challenger
  b uuid not null references profiles(id) on delete cascade,   -- opponent
  stake numeric not null default 0,
  friendly boolean not null,
  status text not null default 'pending',   -- pending | live | done | declined | cancelled | expired
  deck int[], a_cards int[] not null default '{}', b_cards int[] not null default '{}',
  a_done boolean not null default false, b_done boolean not null default false,
  winner uuid, result text,
  created_at timestamptz not null default now(),
  a_acted timestamptz not null default now(), b_acted timestamptz not null default now()
);
alter table pvp_matches enable row level security;   -- no policies: only functions touch it

-- settle a live match once both players are done (internal)
create or replace function _pvp_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; ta int; tb int; w uuid; res text;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or not (m.a_done and m.b_done) then return; end if;
  ta := _bj_total(m.a_cards); tb := _bj_total(m.b_cards);
  if (ta > 21 and tb > 21) or (ta = tb) then w := null; res := 'tie';
  elsif ta > 21 then w := m.b; elsif tb > 21 then w := m.a;
  elsif ta > tb then w := m.a; else w := m.b; end if;
  if w is not null then res := 'win'; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
end $$;

-- housekeeping for my matches: expire old challenges, auto-stand idle players (internal)
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if not m.a_done and m.a_acted < now() - interval '90 seconds' then update pvp_matches set a_done = true where id = m.id; end if;
    if not m.b_done and m.b_acted < now() - interval '90 seconds' then update pvp_matches set b_done = true where id = m.id; end if;
    perform _pvp_settle(m.id);
  end loop;
end $$;

-- what one player is allowed to see
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  is_a boolean := m.a = me;
  mine int[] := case when m.a = me then m.a_cards else m.b_cards end;
  theirs int[] := case when m.a = me then m.b_cards else m.a_cards end;
  shown int[];
begin
  shown := case when m.status = 'done' then theirs else theirs[1:1] end;
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'my_cards', mine, 'my_total', _bj_total(mine), 'my_done', case when is_a then m.a_done else m.b_done end,
    'opp_cards', shown, 'opp_count', cardinality(theirs), 'opp_total', _bj_total(shown),
    'opp_done', case when is_a then m.b_done else m.a_done end,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_settle(uuid) from public, anon, authenticated;
revoke execute on function _pvp_tidy() from public, anon, authenticated;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

create or replace function pvp_challenge(p_user text, p_stake numeric, p_friendly boolean) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); them uuid; bal numeric; m pvp_matches;
begin
  if me is null then raise exception 'Not signed in'; end if;
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
  insert into pvp_matches (a, b, stake, friendly) values (me, them, p_stake, p_friendly) returning * into m;
  return _pvp_view(m, me);
end $$;

create or replace function pvp_accept(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; bal numeric; d int[];
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
  select array_agg(c order by random()) into d from generate_series(0, 51) c;
  update pvp_matches set status = 'live', deck = d[5:], a_cards = array[d[1], d[3]], b_cards = array[d[2], d[4]],
         a_done = _bj_total(array[d[1], d[3]]) = 21, b_done = _bj_total(array[d[2], d[4]]) = 21,
         a_acted = now(), b_acted = now()
   where id = m.id;
  perform _pvp_settle(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

create or replace function pvp_decline(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'pending' then raise exception 'That challenge is gone'; end if;
  if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
  update pvp_matches set status = case when m.a = me then 'cancelled' else 'declined' end where id = m.id;
  return json_build_object('ok', true, 'balance', (select balance from profiles where id = me));
end $$;

create or replace function pvp_move(p_id uuid, p_hit boolean) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; c int[];
begin
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' then raise exception 'No match in play'; end if;
  is_a := m.a = me;
  if (is_a and m.a_done) or (not is_a and m.b_done) then raise exception 'You''re done this hand. Waiting on your opponent.'; end if;
  if is_a then
    c := case when p_hit then m.a_cards || m.deck[1] else m.a_cards end;
    update pvp_matches set a_cards = c, deck = case when p_hit then deck[2:] else deck end,
           a_done = not p_hit or _bj_total(c) >= 21, a_acted = now() where id = m.id;
  else
    c := case when p_hit then m.b_cards || m.deck[1] else m.b_cards end;
    update pvp_matches set b_cards = c, deck = case when p_hit then deck[2:] else deck end,
           b_done = not p_hit or _bj_total(c) >= 21, b_acted = now() where id = m.id;
  end if;
  perform _pvp_settle(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- everything the 1v1 tab needs: incoming / outgoing challenges and my current match
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

-- refill is also blocked while you have a 1v1 going
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from crash_rounds where user_id = auth.uid() and status = 'live'
               and extract(epoch from clock_timestamp() - started_at) < ln(crash_point) / 0.09)
     or exists (select 1 from ride_rounds where user_id = auth.uid() and status = 'live')
     or exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live')
     or exists (select 1 from pvp_matches where (a = auth.uid() or b = auth.uid()) and status in ('pending', 'live')) then
    raise exception 'Finish your current game before refilling';
  end if;
  update profiles set balance = 100 where id = auth.uid() and balance < 10 returning balance into bal;
  if bal is null then raise exception 'Refill only works under 10 coins'; end if;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Safety ==========
-- 2) a balance can never be saved as NaN or infinity: keep the old value instead
create or replace function _sane_balance() returns trigger
language plpgsql as $$
begin
  if new.balance = 'NaN'::numeric or new.balance = 'Infinity'::numeric or new.balance = '-Infinity'::numeric then
    new.balance := coalesce(old.balance, 0);
  end if;
  return new;
end $$;
drop trigger if exists sane_balance on profiles;
create trigger sane_balance before insert or update on profiles
for each row execute function _sane_balance();

-- 3) boosts stack up to 30 minutes max (much longer and the chart number overflows)
create or replace function admin_boost(p_user text) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; until timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles
     set boost_until = least(greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '3 minutes',
                             clock_timestamp() + interval '30 minutes')
   where id = them returning boost_until into until;
  return json_build_object('user', them_name, 'until', until);
end $$;

-- ========== Moderators + Bad luck ==========
alter table profiles add column if not exists badluck_until timestamptz;

create table if not exists moderators (user_id uuid primary key references profiles(id) on delete cascade);
create table if not exists badluck_log (by_user uuid, target uuid, at timestamptz not null default now());
alter table moderators enable row level security;
alter table badluck_log enable row level security;

-- make Yoink a moderator
insert into moderators select id from profiles where lower(username) = 'yoink' on conflict do nothing;

-- 'admin', 'mod', or null
create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from admins where user_id = auth.uid()) then 'admin'
              when exists (select 1 from moderators where user_id = auth.uid()) then 'mod' end
$$;

create or replace function _bad_luck_now(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select badluck_until > clock_timestamp() from profiles where id = p_uid), false)
$$;

-- admin: make / remove a moderator
create or replace function admin_set_mod(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on then insert into moderators values (them) on conflict do nothing;
  else delete from moderators where user_id = them; end if;
  return json_build_object('user', them_name, 'mod', p_on);
end $$;

-- how many Bad luck uses a moderator has left today (Pacific time). null = unlimited (admin)
create or replace function bad_luck_left() returns int
language sql stable security definer set search_path = public as $$
  select case when my_role() = 'admin' then null
              when my_role() = 'mod' then greatest(0, 3 - (select count(*)::int from badluck_log
                 where by_user = auth.uid() and (at at time zone 'America/Los_Angeles')::date = (now() at time zone 'America/Los_Angeles')::date))
              else 0 end
$$;

-- give someone 1 minute of Bad luck (stacks)
create or replace function give_bad_luck(p_user text) returns json
language plpgsql security definer set search_path = public as $$
declare role text := my_role(); them uuid; them_name text; until timestamptz;
begin
  if role is null then raise exception 'Moderators only'; end if;
  if role = 'mod' and bad_luck_left() <= 0 then raise exception 'No Bad luck uses left today (3 per day)'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if role = 'mod' and exists (select 1 from admins where user_id = them) then raise exception 'Can''t use Bad luck on an admin'; end if;
  update profiles set badluck_until = greatest(coalesce(badluck_until, clock_timestamp()), clock_timestamp()) + interval '1 minute'
   where id = them returning badluck_until into until;
  insert into badluck_log (by_user, target) values (auth.uid(), them);
  return json_build_object('user', them_name, 'until', until, 'left', bad_luck_left());
end $$;

-- coin flip: bad luck = always the side you didn't pick
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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

-- rocket: bad luck = crashes at 1.01x
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

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then cp := 1.01;
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric;
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;

  return json_build_object('round_id', rid, 'balance', bal);
end $$;

select 'moderators:' as what, string_agg(p.username, ', ') from moderators m join profiles p on p.id = m.user_id;
notify pgrst, 'reload schema';

-- ========== Remove effects ==========

create or replace function clear_effect(p_user text, p_kind text) returns json
language plpgsql security definer set search_path = public as $$
declare role text := my_role(); them uuid; them_name text; refunded numeric := 0; x numeric;
begin
  if role is null then raise exception 'Moderators only'; end if;
  if p_kind not in ('boost', 'bad') then raise exception 'Unknown effect'; end if;
  if p_kind = 'boost' and role <> 'admin' then raise exception 'Only admins can remove boosts'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;

  if p_kind = 'boost' then update profiles set boost_until = null where id = them;
  else update profiles set badluck_until = null where id = them; end if;

  -- refund anything in progress so the effect can't still hit (or pay) them
  select coalesce(sum(bet), 0) into x from ride_rounds where user_id = them and status = 'live';
  refunded := refunded + x;
  update ride_rounds set status = 'done', payout = bet, holding = false where user_id = them and status = 'live';
  select coalesce(sum(bet), 0) into x from crash_rounds where user_id = them and status = 'live';
  refunded := refunded + x;
  update crash_rounds set status = 'cashed', cashout = 1 where user_id = them and status = 'live';
  select coalesce(sum(bet), 0) into x from bj_hands where user_id = them and status = 'live';
  refunded := refunded + x;
  update bj_hands set status = 'done', result = 'void', payout = bet where user_id = them and status = 'live';
  update profiles set balance = balance + refunded where id = them;

  return json_build_object('user', them_name, 'kind', p_kind, 'refunded', refunded);
end $$;

notify pgrst, 'reload schema';

-- ========== Rush hour ==========
create table if not exists site_state (id int primary key default 1 check (id = 1), rush_until timestamptz);
insert into site_state (id) values (1) on conflict do nothing;
alter table site_state enable row level security;
drop policy if exists "site state readable" on site_state;
create policy "site state readable" on site_state for select to anon, authenticated using (true);

create or replace function _rush_now() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rush_until > clock_timestamp() from site_state where id = 1), false)
$$;

-- admin: start (or extend) rush hour by 3 minutes
create or replace function admin_rush(p_on boolean default true) returns json
language plpgsql security definer set search_path = public as $$
declare until timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_on then
    update site_state set rush_until = greatest(coalesce(rush_until, clock_timestamp()), clock_timestamp()) + interval '3 minutes'
     where id = 1 returning rush_until into until;
  else
    update site_state set rush_until = null where id = 1;
  end if;
  return json_build_object('until', until);
end $$;

-- coin flip: bad luck = always lose; rush hour = 75% win
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
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

-- rocket: bad luck = crashes at 1.01x; rush hour = flies much higher
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
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then cp := 1.00;          -- bad luck: blows up instantly
  elsif _rush_now() then                                     -- rush hour: 1.8x minimum, ~7x typical
    r := random();
    cp := least(1000, greatest(1.8, floor(3.5 / (1 - r) * 100) / 100))::numeric;
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric;
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;

  return json_build_object('round_id', rid, 'balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Refill (fixed) ==========

create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  bal numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;

  -- tidy up leftovers from closed tabs
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

  select balance into bal from profiles where id = me;
  if bal >= 10 then raise exception 'Refill only works under 10 coins (you have %)', round(bal, 2); end if;
  update profiles set balance = 100 where id = me returning balance into bal;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Gifting off ==========
create or replace function gift_coins(p_to text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Gifting is turned off';
end $$;
notify pgrst, 'reload schema';

-- ================= Bot auto-ban =================

alter table profiles add column if not exists banned boolean not null default false;

create or replace function _is_bot_name(n text) returns boolean
language sql immutable as $$
  select n ~ '^[a-z]{10,}$' and (                                   -- 10+ lowercase letters only
       n ~ '[bcdfghjklmnpqrstvwxyz]{4}'                             -- 4 consonants in a row
    or n ~ 'q[^u]'                                                  -- q without u
    or length(regexp_replace(n, '[^aeiou]', '', 'g'))::float8 / length(n) < 0.25   -- barely any vowels
  )
$$;

-- new bot sign-ups get banned instantly
create or replace function _ban_bot_signup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _is_bot_name(coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1))) then
    new.banned_until := 'infinity';
  end if;
  return new;
end $$;
drop trigger if exists ban_bot_signup on auth.users;
create trigger ban_bot_signup before insert on auth.users
for each row execute function _ban_bot_signup();

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  nm text := coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1));
  bot boolean := _is_bot_name(nm);
begin
  insert into profiles (id, username, banned, balance)
  values (new.id, nm, bot, case when bot then 0 else 1000 end);
  return new;
end $$;


-- ================= Bot ban v2 + refill 500 =================

alter table profiles add column if not exists banned boolean not null default false;

-- letter pairs that almost never show up in real words or names
create or replace function _rare_pairs() returns text[] language sql immutable as $$
  select array[
    'aa','aj','ao','aq','bf','bg','bh','bk','bn','bp','bq','bv','bw','bx','bz','cb',
    'cd','cf','cg','cj','cm','cn','cp','cq','cv','cw','cx','cz','dk','dq','dx','dz',
    'ej','ez','fd','fh','fj','fk','fm','fn','fp','fq','fv','fw','fx','fz','gj','gk',
    'gq','gv','gx','gz','hg','hj','hk','hq','hv','hx','hz','ih','ii','ij','iq','iu',
    'iw','iy','jb','jc','jd','jf','jg','jh','jj','jk','jl','jm','jn','jq','jt','jv',
    'jw','jx','jy','jz','kj','kq','kv','kx','kz','lh','lj','lq','lx','lz','md','mg',
    'mh','mj','mk','mq','mt','mv','mw','mx','mz','nq','nx','nz','oj','oq','oz','pg',
    'pj','pk','pn','pq','pv','pw','px','pz','qd','qe','qf','qg','qh','qj','qk','qm',
    'qn','qo','qq','qr','qs','qt','qv','qw','qx','qy','qz','rj','rq','rx','rz','sj',
    'sv','sx','sz','tg','tj','tk','tq','tv','tx','tz','uh','uj','uq','uu','uv','uw',
    'ux','uz','vb','vc','vd','vf','vg','vh','vj','vk','vl','vm','vn','vp','vq','vr',
    'vt','vu','vv','vw','vx','vz','wg','wj','wq','wu','wv','wx','wz','xg','xj','xk',
    'xn','xq','xw','xz','yq','yx','yy','zc','zg','zj','zk','zm','zn','zq','zt','zv',
    'zw','zx'
  ]
$$;

create or replace function _is_bot_name(n text) returns boolean
language plpgsql immutable as $$
declare rare text[] := _rare_pairs(); c int := 0;
begin
  if n is null or n !~ '^[a-z]{10,}$' then return false; end if;   -- only 10+ lowercase letters
  if lower(n) in ('laobaoshiangeko', 'israelistorage') then return false; end if;
  if n ~ 'q[^u]' then return true; end if;
  for i in 1 .. length(n) - 1 loop
    if substr(n, i, 2) = any(rare) then c := c + 1; end if;
  end loop;
  return c >= 2;
end $$;

create or replace function _is_bot_signup(n text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if _is_bot_name(n) then return true; end if;
  -- burst: 3+ other random lowercase names in the last 10 minutes
  return n ~ '^[a-z]{10,}$' and (
    select count(*) from profiles
    where username ~ '^[a-z]{10,}$' and created_at > now() - interval '10 minutes'
  ) >= 3;
end $$;

create or replace function _ban_bot_signup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _is_bot_signup(coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1))) then
    new.banned_until := 'infinity';
  end if;
  return new;
end $$;
drop trigger if exists ban_bot_signup on auth.users;
create trigger ban_bot_signup before insert on auth.users
for each row execute function _ban_bot_signup();

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  nm text := coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1));
  bot boolean := coalesce(new.banned_until = 'infinity', false);
begin
  insert into profiles (id, username, banned, balance)
  values (new.id, nm, bot, case when bot then 0 else 1000 end);
  return new;
end $$;


-- refill now gives 500
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  bal numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;

  -- tidy up leftovers from closed tabs
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

  select balance into bal from profiles where id = me;
  if bal >= 10 then raise exception 'Refill only works under 10 coins (you have %)', round(bal, 2); end if;
  update profiles set balance = 500 where id = me returning balance into bal;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ================= Admin gift =================
create or replace function admin_give(p_user text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; bal numeric;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 then raise exception 'Enter an amount'; end if;
  if p_amount > 1e12 then raise exception 'Max gift is 1,000,000,000,000'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1 for update;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set balance = balance + p_amount where id = them returning balance into bal;
  return json_build_object('user', them_name, 'gave', p_amount, 'balance', bal);
end $$;
revoke execute on function admin_give(text, numeric) from anon;

notify pgrst, 'reload schema';

-- ================= Harsher bad luck =================
drop function if exists _ride_path(bigint, int);
drop function if exists _ride_path(bigint, int, int);
drop function if exists _ride_path(bigint, int, int, int);
create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0) returns float8[]
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
  cut int := -1; rug int := 0; base float8 := 100;
  k int; ev int; done boolean;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_bad then                                    -- bad luck: fake chop, then a rug to 40%, every 0.6s
      k := (i - 1) % 6;
      if k < 3 then p := p * exp((u2 - 0.5) * 0.01);
      else p := p * exp(ln(0.4) / 3);
      end if;
      ev_left := 0; rug := 0; v := 0;
      p := least(greatest(p, 1e-200), 1e200);
      arr := arr || p;
      continue;
    end if;
    if i <= p_boost then                                  -- admin boost: fast nonstop pump (~+22%/s), no dumps
      p := least(p * exp(0.02 + (u2 - 0.5) * 0.02), 1e200);
      ev_left := 0; rug := 0; v := 0;
      arr := arr || p;
      continue;
    end if;
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.98 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.8 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53));
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.15 then
          cut := 3 + floor((u1 * 331 - floor(u1 * 331)) * (d - 3))::int;
        else
          cut := -1;
        end if;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := 0.15 + 0.25 * (u1 * 53 - floor(u1 * 53));
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0; done := false;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        if k = cut then
          ev_left := 0; rug := 3;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: crash to half of where the pump started
      p := p * exp(ln(base * 0.5 / p) / rug);
      rug := rug - 1; v := 0; done := true;
    end if;
    if not done then                                      -- normal chop keeps going during pumps
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
    p := least(greatest(p, 1e-200), 1e200);                -- never overflow
    arr := arr || p;
  end loop;
  return arr;
end $$;

create or replace function ride_version() returns int language sql immutable as $$ select 35 $$;
notify pgrst, 'reload schema';

-- ================= Gifting back (10/day) =================

create or replace function gifts_left() returns int
language sql stable security definer set search_path = public as $$
  select greatest(0, 10 - (select count(*)::int from gifts
    where from_id = auth.uid()
      and (created_at at time zone 'America/Los_Angeles')::date = (now() at time zone 'America/Los_Angeles')::date))
$$;

create or replace function gift_coins(p_to text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  bal numeric;
  them_name text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if (select banned from profiles where id = me) then raise exception 'Your account is banned'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount <= 0 or p_amount <> p_amount then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) and not banned order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  perform 1 from profiles where id in (me, them) order by id for update;
  if gifts_left() <= 0 then raise exception 'You''ve used all 10 gifts for today. Resets at midnight.'; end if;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  update profiles set balance = balance + p_amount where id = them;
  insert into gifts (from_id, to_id, amount) values (me, them, p_amount);
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount, 'left', gifts_left());
end $$;

notify pgrst, 'reload schema';

-- ================= Stronger rush hour =================
drop function if exists _ride_path(bigint, int);
drop function if exists _ride_path(bigint, int, int);
drop function if exists _ride_path(bigint, int, int, int);
create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0) returns float8[]
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
  cut int := -1; rug int := 0; base float8 := 100;
  k int; ev int; done boolean;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_bad then                                    -- bad luck: fake chop, then a rug to 40%, every 0.6s
      k := (i - 1) % 6;
      if k < 3 then p := p * exp((u2 - 0.5) * 0.01);
      else p := p * exp(ln(0.4) / 3);
      end if;
      ev_left := 0; rug := 0; v := 0;
      p := least(greatest(p, 1e-200), 1e200);
      arr := arr || p;
      continue;
    end if;
    if i <= p_boost then                                  -- admin boost: fast nonstop pump (~+22%/s), no dumps
      p := least(p * exp(0.02 + (u2 - 0.5) * 0.02), 1e200);
      ev_left := 0; rug := 0; v := 0;
      arr := arr || p;
      continue;
    end if;
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.96 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.92 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.8 + 0.7 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.15 then
          cut := 3 + floor((u1 * 331 - floor(u1 * 331)) * (d - 3))::int;
        else
          cut := -1;
        end if;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := (case when i <= p_rush then 0.5 else 1 end) * (0.15 + 0.25 * (u1 * 53 - floor(u1 * 53)));   -- rush: half-size dumps
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0; done := false;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        if k = cut then
          ev_left := 0; rug := 3;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: crash to half of where the pump started
      p := p * exp(ln(base * 0.5 / p) / rug);
      rug := rug - 1; v := 0; done := true;
    end if;
    if not done then                                      -- normal chop keeps going during pumps
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
    p := least(greatest(p, 1e-200), 1e200);                -- never overflow
    arr := arr || p;
  end loop;
  return arr;
end $$;

create or replace function ride_version() returns int language sql immutable as $$ select 36 $$;
notify pgrst, 'reload schema';

-- ================= Admin gift log =================
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    select g.created_at, f.username, t.username, g.amount
    from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
    where coalesce(trim(p_user), '') = ''
       or lower(f.username) = lower(trim(p_user)) or lower(t.username) = lower(trim(p_user))
    order by g.created_at desc
    limit 200;
end $$;
revoke execute on function admin_gift_log(text) from anon;

notify pgrst, 'reload schema';

-- ================= Rush hour tuned down a bit =================
drop function if exists _ride_path(bigint, int);
drop function if exists _ride_path(bigint, int, int);
drop function if exists _ride_path(bigint, int, int, int);
create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0) returns float8[]
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
  cut int := -1; rug int := 0; base float8 := 100;
  k int; ev int; done boolean;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_bad then                                    -- bad luck: fake chop, then a rug to 40%, every 0.6s
      k := (i - 1) % 6;
      if k < 3 then p := p * exp((u2 - 0.5) * 0.01);
      else p := p * exp(ln(0.4) / 3);
      end if;
      ev_left := 0; rug := 0; v := 0;
      p := least(greatest(p, 1e-200), 1e200);
      arr := arr || p;
      continue;
    end if;
    if i <= p_boost then                                  -- admin boost: fast nonstop pump (~+22%/s), no dumps
      p := least(p * exp(0.02 + (u2 - 0.5) * 0.02), 1e200);
      ev_left := 0; rug := 0; v := 0;
      arr := arr || p;
      continue;
    end if;
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.97 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.88 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.15 then
          cut := 3 + floor((u1 * 331 - floor(u1 * 331)) * (d - 3))::int;
        else
          cut := -1;
        end if;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := (case when i <= p_rush then 0.7 else 1 end) * (0.15 + 0.25 * (u1 * 53 - floor(u1 * 53)));   -- rush: half-size dumps
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0; done := false;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        if k = cut then
          ev_left := 0; rug := 3;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: crash to half of where the pump started
      p := p * exp(ln(base * 0.5 / p) / rug);
      rug := rug - 1; v := 0; done := true;
    end if;
    if not done then                                      -- normal chop keeps going during pumps
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
    p := least(greatest(p, 1e-200), 1e200);                -- never overflow
    arr := arr || p;
  end loop;
  return arr;
end $$;

create or replace function ride_version() returns int language sql immutable as $$ select 37 $$;
notify pgrst, 'reload schema';

-- ================= Escalating rebirth cost =================
create or replace function _rebirth_cost(p_done int) returns numeric
language sql immutable as $$ select 50000::numeric * (coalesce(p_done, 0) + 1) $$;

create or replace function rebirth() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rb int;
  cost numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance, rebirths into bal, rb from profiles where id = auth.uid() for update;
  cost := _rebirth_cost(rb);
  if bal < cost then raise exception 'You need % coins for rebirth ▲%', to_char(cost, 'FM999,999,999,999'), rb + 1; end if;
  update profiles set balance = 1000, rebirths = rebirths + 1 where id = auth.uid()
    returning balance, rebirths into bal, rb;
  return json_build_object('balance', bal, 'rebirths', rb, 'next_cost', _rebirth_cost(rb));
end $$;

notify pgrst, 'reload schema';

-- ================= Ride v4: streamed chart (seed stays secret) =================
-- (ride_feed), so nobody can see what's coming. Holds are reported live; Stop replays the chart to pay out.

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
alter table ride_rounds add column if not exists bad_steps int not null default 0;
alter table ride_rounds add column if not exists rush_steps int not null default 0;
create table if not exists site_state (id int primary key default 1 check (id = 1), rush_until timestamptz);
insert into site_state (id) values (1) on conflict do nothing;
alter table profiles add column if not exists badluck_until timestamptz;
alter table profiles add column if not exists boost_until timestamptz;

-- the chart: momentum random walk. MUST match ridePath() in index.html
drop function if exists _ride_path(bigint, int);
drop function if exists _ride_path(bigint, int, int);
drop function if exists _ride_path(bigint, int, int, int);
drop function if exists _ride_gen(bigint, int, int, int, int);
create or replace function _ride_gen(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0,
  out px float8[], out evs int[], out heats float8[])
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
  cut int := -1; rug int := 0; base float8 := 100;
  k int; ev int; done boolean;
  arr float8[] := array[100.0];
  ea int[] := array[0];
  ha float8[] := array[1.0];
  evc int;
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_bad then                                    -- bad luck: fake chop, then a rug to 40%, every 0.6s
      k := (i - 1) % 6;
      if k < 3 then p := p * exp((u2 - 0.5) * 0.01);
      else p := p * exp(ln(0.4) / 3);
      end if;
      ev_left := 0; rug := 0; v := 0;
      p := least(greatest(p, 1e-200), 1e200);
      arr := arr || p; ea := ea || (case when k < 3 then 0 else -2 end); ha := ha || heat;
      continue;
    end if;
    if i <= p_boost then                                  -- admin boost: fast nonstop pump (~+22%/s), no dumps
      p := least(p * exp(0.02 + (u2 - 0.5) * 0.02), 1e200);
      ev_left := 0; rug := 0; v := 0;
      arr := arr || p; ea := ea || 2; ha := ha || heat;
      continue;
    end if;
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.97 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.88 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.15 then
          cut := 3 + floor((u1 * 331 - floor(u1 * 331)) * (d - 3))::int;
        else
          cut := -1;
        end if;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := (case when i <= p_rush then 0.7 else 1 end) * (0.15 + 0.25 * (u1 * 53 - floor(u1 * 53)));   -- rush: half-size dumps
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0; done := false; evc := 0;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        if k = cut then
          ev_left := 0; rug := 3;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1; evc := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1; evc := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: crash to half of where the pump started
      p := p * exp(ln(base * 0.5 / p) / rug);
      rug := rug - 1; v := 0; done := true; evc := -2;
    end if;
    if not done then                                      -- normal chop keeps going during pumps
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
    p := least(greatest(p, 1e-200), 1e200);                -- never overflow
    arr := arr || p; ea := ea || evc; ha := ha || heat;
  end loop;
  px := arr; evs := ea; heats := ha;
end $$;

create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0) returns float8[]
language sql immutable as $$ select (_ride_gen(p_seed, n, p_boost, p_bad, p_rush)).px $$;

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
  return greatest(least(coalesce(p_step, k), k), k - 10, rd.last_step);   -- no future steps, at most 1s back
end $$;

-- bump this whenever the chart math changes; must match RIDE_VERSION in index.html
create or replace function ride_version() returns int language sql immutable as $$ select 38 $$;

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

  path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 500000);                          -- max win 500k per round (RIDE_MAX_WIN in index.html)
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
  bad int;
  rush int;
  sd bigint := floor(random() * 2147483645)::bigint + 1;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_ver is distinct from ride_version() then raise exception 'Ride was updated. Refresh the page.'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;

  perform ride_cleanup();

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  select greatest(0, floor(extract(epoch from (boost_until - clock_timestamp())) / 0.1))::int into bs
    from profiles where id = auth.uid() and boost_until > clock_timestamp();
  select greatest(0, floor(extract(epoch from (badluck_until - clock_timestamp())) / 0.1))::int into bad
    from profiles where id = auth.uid() and badluck_until > clock_timestamp();
  select greatest(0, floor(extract(epoch from (rush_until - clock_timestamp())) / 0.1))::int into rush
    from site_state where id = 1 and rush_until > clock_timestamp();
  insert into ride_rounds (user_id, bet, seed, boost_steps, bad_steps, rush_steps)
    values (auth.uid(), p_bet, sd, coalesce(bs, 0), coalesce(bad, 0), coalesce(rush, 0)) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal, 'boost_steps', coalesce(bs, 0), 'bad_steps', coalesce(bad, 0), 'rush_steps', coalesce(rush, 0));
end $$;

-- the chart, streamed: only points up to "now" (the seed stays secret so nobody can see the future)
create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  g := _ride_gen(rd.seed, k, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  return json_build_object('k', k, 'from', a,
    'p', to_json(g.px[a + 1 : k + 1]), 'ev', to_json(g.evs[a + 1 : k + 1]), 'heat', to_json(g.heats[a + 1 : k + 1]),
    'live', rd.status = 'live');
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

-- ================= Waiting room =================

alter table profiles add column if not exists approved boolean not null default true;   -- existing accounts: in
alter table profiles alter column approved set default false;                            -- new accounts: waiting

-- waiting players' coins are frozen: no bets, daily, refill, gifts in or out
create or replace function _waiting_frozen() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not new.approved and new.balance is distinct from old.balance and not is_admin() then
    raise exception 'Your account is waiting to be accepted by an admin';
  end if;
  return new;
end $$;
drop trigger if exists waiting_frozen on profiles;
create trigger waiting_frozen before update on profiles
for each row execute function _waiting_frozen();

-- no 1v1s (even friendly) with someone still waiting
create or replace function _pvp_needs_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from profiles where id in (new.a, new.b) and not approved) then
    raise exception 'That player is still waiting to be accepted';
  end if;
  return new;
end $$;
drop trigger if exists pvp_needs_approved on pvp_matches;
create trigger pvp_needs_approved before insert on pvp_matches
for each row execute function _pvp_needs_approved();

-- admin: who's waiting
create or replace function admin_pending() returns table(username text, joined timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select p.username, p.created_at from profiles p
    where not p.approved and not p.banned order by p.created_at;
end $$;

-- admin: accept (p_ok = true) or reject = delete the account (p_ok = false)
create or replace function admin_approve(p_user text, p_ok boolean) returns json
language plpgsql security definer set search_path = public, auth as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_ok then update profiles set approved = true where id = them;
  else
    if exists (select 1 from admins where user_id = them) then raise exception 'Can''t delete an admin'; end if;
    delete from auth.users where id = them;
  end if;
  return json_build_object('user', them_name, 'ok', p_ok);
end $$;
revoke execute on function admin_pending() from anon;
revoke execute on function admin_approve(text, boolean) from anon;

notify pgrst, 'reload schema';

-- ================= Waiting room: reject = hide =================
alter table profiles add column if not exists rejected_at timestamptz;

create or replace function admin_pending() returns table(username text, joined timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select p.username, p.created_at from profiles p
    where not p.approved and not p.banned and p.rejected_at is null order by p.created_at;
end $$;

create or replace function admin_approve(p_user text, p_ok boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_ok then update profiles set approved = true, rejected_at = null where id = them;
  else update profiles set rejected_at = now() where id = them;
  end if;
  return json_build_object('user', them_name, 'ok', p_ok);
end $$;

-- player: get back on the waiting list after being turned down (once every 10 minutes)
create or replace function ask_again() returns json
language plpgsql security definer set search_path = public as $$
declare r timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select rejected_at into r from profiles where id = auth.uid();
  if r is null then return json_build_object('ok', true); end if;
  if r > now() - interval '10 minutes' then
    raise exception 'You can ask again in % min', ceil(extract(epoch from (r + interval '10 minutes' - now())) / 60);
  end if;
  update profiles set rejected_at = null where id = auth.uid();
  return json_build_object('ok', true);
end $$;

notify pgrst, 'reload schema';
