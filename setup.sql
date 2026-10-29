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
  payout := least(payout, rd.bet + 5000000);   -- max win 5m per round
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
  pay := least(pay, h.bet + 5000000);   -- max win 5m per hand
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
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
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
  if p_bet > 10000000 then raise exception 'Max Coin Flip bet is 10,000,000'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip (max bet 1m)

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
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;

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

-- ================= Ride v4.1: cached chart (less lag) =================
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
  delete from ride_paths where round_id = rd.id;
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
  if p_bet > 500000 then raise exception 'Max bet is 500,000'; end if;

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
create table if not exists ride_paths (
  round_id uuid primary key references ride_rounds(id) on delete cascade,
  p float8[] not null, ev int[] not null, heat float8[] not null
);
alter table ride_paths enable row level security;   -- no policies: only functions touch it (it holds the future)

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps);
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
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

-- ================= Ride v4.2: 1.5s hold window for slow wifi =================
create or replace function _ride_clamp(rd ride_rounds, p_step int) returns int
language plpgsql stable as $$
declare
  k int := _ride_k(rd);
begin
  return greatest(least(coalesce(p_step, k), k), k - 15, rd.last_step);   -- no future steps, at most 1.5s back (slow wifi)
end $$;

-- ================= Online dots =================
alter table profiles add column if not exists last_seen timestamptz;

-- the site calls this every 30s while it's open
create or replace function heartbeat() returns void
language sql security definer set search_path = public as $$
  update profiles set last_seen = now() where id = auth.uid()
$$;
revoke execute on function heartbeat() from anon;

notify pgrst, 'reload schema';

-- ================= Mod grants =================
create table if not exists mod_grants (by_user uuid not null, target uuid not null, amount numeric not null, at timestamptz not null default now());
alter table mod_grants enable row level security;   -- no policies: only functions touch it

create or replace function mod_grants_left() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'grants', greatest(0, 2 - count(*)),
    'coins', greatest(0, 1000000 - coalesce(sum(amount), 0)))
  from mod_grants
  where by_user = auth.uid()
    and (at at time zone 'America/Los_Angeles')::date = (now() at time zone 'America/Los_Angeles')::date
$$;

create or replace function mod_give(p_user text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; lft json; bal numeric;
begin
  if my_role() is distinct from 'mod' then raise exception 'Moderators only (admins use Gift coins in the admin panel)'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 or p_amount <> p_amount then raise exception 'Enter an amount'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) and not banned and approved order by created_at limit 1;
  if them is null then raise exception 'No player named % (or they''re banned / still waiting)', p_user; end if;
  if them = auth.uid() then raise exception 'You can''t grant coins to yourself'; end if;
  perform pg_advisory_xact_lock(hashtext('mod_give' || auth.uid()::text));   -- no double-spending with two taps at once
  lft := mod_grants_left();
  if (lft->>'grants')::int <= 0 then raise exception 'You''ve used both grants for today'; end if;
  if p_amount > (lft->>'coins')::numeric then raise exception 'You can only grant % more today', to_char((lft->>'coins')::numeric, 'FM9,999,999'); end if;
  update profiles set balance = balance + p_amount where id = them returning balance into bal;
  insert into mod_grants (by_user, target, amount) values (auth.uid(), them, p_amount);
  return json_build_object('user', them_name, 'gave', p_amount, 'left', mod_grants_left());
end $$;
revoke execute on function mod_give(text, numeric) from anon;

notify pgrst, 'reload schema';

-- ================= Ride: softer rug pulls =================
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
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.10 then   -- 10% of pumps rug (was 15%)
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
          ev_left := 0; rug := 5;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1; evc := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1; evc := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: drop to 70% of where the pump started, over 0.5s (was 50% in 0.3s)
      p := p * exp(least(0, ln(base * 0.7 / p)) / rug);
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
  return greatest(least(coalesce(p_step, k), k), k - 15, rd.last_step);   -- no future steps, at most 1.5s back (slow wifi)
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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 500000);                          -- max win 500k per round (RIDE_MAX_WIN in index.html)
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
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
  if p_bet > 500000 then raise exception 'Max bet is 500,000'; end if;

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
create table if not exists ride_paths (
  round_id uuid primary key references ride_rounds(id) on delete cascade,
  p float8[] not null, ev int[] not null, heat float8[] not null
);
alter table ride_paths enable row level security;   -- no policies: only functions touch it (it holds the future)

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps);
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
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

-- ================= Ride: original rugs, no max win =================
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
  return greatest(least(coalesce(p_step, k), k), k - 15, rd.last_step);   -- no future steps, at most 1.5s back (slow wifi)
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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 5000000);                         -- max win 5m per round (RIDE_MAX_WIN in index.html)
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
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
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;

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
create table if not exists ride_paths (
  round_id uuid primary key references ride_rounds(id) on delete cascade,
  p float8[] not null, ev int[] not null, heat float8[] not null
);
alter table ride_paths enable row level security;   -- no policies: only functions touch it (it holds the future)

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps);
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
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

-- ================= Owner protection (+ Yoink admin) =================

-- the owner (max) is remembered by account id, so renaming can't fake it
create table if not exists site_owner (id uuid primary key);
alter table site_owner enable row level security;   -- no policies: only functions read it
insert into site_owner select id from profiles where username = 'max' on conflict do nothing;

-- other admins/mods can't touch the owner: no taking coins, banning, renaming, rebirths, boosts, bad luck,
-- waiting room. Coins going UP (gifts, 1v1 wins) are still fine. SQL you run yourself is never blocked.
create or replace function _protect_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or auth.uid() = new.id or not exists (select 1 from site_owner where id = new.id) then
    return new;
  end if;
  if new.balance < old.balance
     or new.banned is distinct from old.banned
     or new.username is distinct from old.username
     or new.rebirths is distinct from old.rebirths
     or new.boost_until is distinct from old.boost_until
     or new.badluck_until is distinct from old.badluck_until
     or new.approved is distinct from old.approved then
    raise exception 'Only max can change max''s account';
  end if;
  return new;
end $$;
drop trigger if exists protect_owner on profiles;
create trigger protect_owner before update on profiles
for each row execute function _protect_owner();

-- also can't delete or demote the owner
create or replace function _protect_owner_rows() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() <> old.user_id and exists (select 1 from site_owner where id = old.user_id) then
    raise exception 'Only max can change max''s account';
  end if;
  return old;
end $$;
drop trigger if exists protect_owner_admin on admins;
create trigger protect_owner_admin before delete on admins
for each row execute function _protect_owner_rows();

create or replace function _protect_owner_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() <> old.id and exists (select 1 from site_owner where id = old.id) then
    raise exception 'Only max can change max''s account';
  end if;
  return old;
end $$;
drop trigger if exists protect_owner_delete on profiles;
create trigger protect_owner_delete before delete on profiles
for each row execute function _protect_owner_delete();

-- Yoink: admin (and no longer listed as a mod)
insert into admins select id from profiles where lower(username) = 'yoink' on conflict do nothing;
delete from moderators where user_id = (select id from profiles where lower(username) = 'yoink');
update profiles set approved = true where lower(username) = 'yoink';


-- ================= Owner-only: bans + mods =================

create or replace function am_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from site_owner where id = auth.uid())
$$;

-- banning / unbanning: owner only (SQL you run yourself and the bot auto-ban still work)
create or replace function _owner_only_ban() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.banned is distinct from old.banned and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can ban or unban';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_ban on profiles;
create trigger owner_only_ban before update on profiles
for each row execute function _owner_only_ban();

-- making / removing mods: owner only
create or replace function _owner_only_mods() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not am_owner() then
    raise exception 'Only max can make or remove mods';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists owner_only_mods on moderators;
create trigger owner_only_mods before insert or delete on moderators
for each row execute function _owner_only_mods();

notify pgrst, 'reload schema';

-- ================= Gift messages =================
alter table gifts add column if not exists message text;

drop function if exists gift_coins(text, numeric);
create or replace function gift_coins(p_to text, p_amount numeric, p_message text default null) returns json
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
  p_message := nullif(left(trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')), 80), '');   -- optional note, 80 chars max
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
  insert into gifts (from_id, to_id, amount, message) values (me, them, p_amount, p_message);
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount, 'left', gifts_left());
end $$;
revoke execute on function gift_coins(text, numeric, text) from anon;

create or replace function my_new_gifts() returns json
language plpgsql security definer set search_path = public as $$
declare
  out json;
begin
  select coalesce(json_agg(json_build_object('from', p.username, 'amount', g.amount, 'message', g.message) order by g.created_at), '[]')
    into out
    from gifts g join profiles p on p.id = g.from_id
   where g.to_id = auth.uid() and not g.seen;
  update gifts set seen = true where to_id = auth.uid() and not seen;
  return out;
end $$;

drop function if exists admin_gift_log(text);
create or replace function admin_gift_log(p_user text default null) returns table(at timestamptz, from_user text, to_user text, amount numeric, message text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    select g.created_at, f.username, t.username, g.amount, g.message
    from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
    where coalesce(trim(p_user), '') = ''
       or lower(f.username) = lower(trim(p_user)) or lower(t.username) = lower(trim(p_user))
    order by g.created_at desc
    limit 200;
end $$;
revoke execute on function admin_gift_log(text) from anon;

notify pgrst, 'reload schema';

-- (max win 2m applied in crash_cashout / flip_coin / _bj_settle / _ride_finish above)

-- ================= Owner-only rush/boost + staff log =================

-- ---------- Rush hour + Boost: owner only ----------
create or replace function _owner_only_rush() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.rush_until is distinct from old.rush_until and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can start or end rush hour';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_rush on site_state;
create trigger owner_only_rush before update on site_state
for each row execute function _owner_only_rush();

create or replace function _owner_only_boost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.boost_until is not null and new.boost_until is distinct from old.boost_until
     and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can boost';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_boost on profiles;
create trigger owner_only_boost before update on profiles
for each row execute function _owner_only_boost();

-- ---------- Staff activity log ----------
create table if not exists staff_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid, actor_name text, target_name text, what text not null
);
alter table staff_log enable row level security;   -- no policies: only functions touch it

create or replace function _is_staff_not_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and not am_owner()
     and (exists (select 1 from admins where user_id = auth.uid()) or exists (select 1 from moderators where user_id = auth.uid()))
$$;

create or replace function _log_staff(p_target text, p_what text) returns void
language sql security definer set search_path = public as $$
  insert into staff_log (actor, actor_name, target_name, what)
  values (auth.uid(), (select username from profiles where id = auth.uid()), p_target, p_what)
$$;

-- anything a non-owner admin/mod does to someone else's account gets written down
create or replace function _watch_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text[] := '{}';
begin
  if not _is_staff_not_owner() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.id <> auth.uid() then perform _log_staff(old.username, 'deleted the account (had ' || to_char(old.balance, 'FM999,999,999,999,990') || ' coins)'); end if;
    return old;
  end if;
  if new.id = auth.uid() then return new; end if;   -- their own playing isn't logged
  if new.balance > old.balance then w := w || ('gave ' || to_char(new.balance - old.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.balance < old.balance then w := w || ('took ' || to_char(old.balance - new.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.username is distinct from old.username then w := w || ('renamed ' || old.username || ' → ' || new.username); end if;
  if new.rebirths is distinct from old.rebirths then w := w || ('rebirths ' || old.rebirths || ' → ' || new.rebirths); end if;
  if new.badluck_until is distinct from old.badluck_until then
    w := w || (case when new.badluck_until is null or new.badluck_until < now() then 'removed bad luck' else 'gave bad luck' end);
  end if;
  if new.boost_until is distinct from old.boost_until and new.boost_until is null then w := w || 'removed boost'::text; end if;
  if new.approved is distinct from old.approved then w := w || (case when new.approved then 'accepted from waiting room' else 'sent to waiting room' end); end if;
  if new.rejected_at is distinct from old.rejected_at and new.rejected_at is not null then w := w || 'rejected from waiting room'::text; end if;
  if array_length(w, 1) > 0 then perform _log_staff(new.username, array_to_string(w, ', ')); end if;
  return new;
end $$;
drop trigger if exists watch_profiles on profiles;
create trigger watch_profiles after update or delete on profiles
for each row execute function _watch_profiles();

create or replace function _watch_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _is_staff_not_owner() and new.text is distinct from old.text then
    perform _log_staff(null, case when coalesce(new.text, '') = '' then 'hid the site notice' else 'set site notice: "' || new.text || '"' end);
  end if;
  return new;
end $$;
drop trigger if exists watch_notice on site_notice;
create trigger watch_notice after update on site_notice
for each row execute function _watch_notice();

-- max only: read the log
create or replace function staff_activity(p_limit int default 200) returns table(at timestamptz, who text, target text, what text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not am_owner() then raise exception 'Only max can see staff activity'; end if;
  return query select l.at, l.actor_name, l.target_name, l.what from staff_log l order by l.id desc limit least(coalesce(p_limit, 200), 1000);
end $$;
revoke execute on function staff_activity(int) from anon;

notify pgrst, 'reload schema';

-- ================= Leaderboard ban =================

alter table profiles add column if not exists board_hidden boolean not null default false;

create or replace function admin_board_ban(p_user text, p_hide boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_hide and exists (select 1 from site_owner where id = them) and not am_owner() then raise exception 'Only max can change max''s account'; end if;
  update profiles set board_hidden = p_hide where id = them;
  if not am_owner() then
    perform _log_staff(them_name, case when p_hide then 'leaderboard banned' else 'un-leaderboard banned' end);
  end if;
  return json_build_object('user', them_name, 'hidden', p_hide);
end $$;
revoke execute on function admin_board_ban(text, boolean) from anon;

notify pgrst, 'reload schema';

-- ================= Gifts must be accepted =================

alter table gifts add column if not exists status text not null default 'accepted';   -- old gifts were auto-accepted
alter table gifts add column if not exists answered_at timestamptz;
create index if not exists gifts_pending on gifts (to_id) where status = 'pending';
alter table gifts add column if not exists sender_seen boolean;
update gifts set sender_seen = true where sender_seen is null and status = 'accepted';

-- send any 24h-old pending gifts back
create or replace function _expire_gifts() returns void
language plpgsql security definer set search_path = public as $$
declare g gifts;
begin
  for g in select * from gifts where status = 'pending' and created_at < now() - interval '24 hours' for update skip locked loop
    update gifts set status = 'expired', answered_at = now() where id = g.id;
    update profiles set balance = balance + g.amount where id = g.from_id;
  end loop;
end $$;

create or replace function gift_coins(p_to text, p_amount numeric, p_message text default null) returns json
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
  p_message := nullif(left(trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')), 80), '');
  if p_amount is null or p_amount <= 0 or p_amount <> p_amount then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) and not banned and approved order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  perform 1 from profiles where id = me for update;
  if gifts_left() <= 0 then raise exception 'You''ve used all 10 gifts for today. Resets at midnight.'; end if;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  insert into gifts (from_id, to_id, amount, message, status) values (me, them, p_amount, p_message, 'pending');
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount, 'left', gifts_left(), 'pending', true);
end $$;
revoke execute on function gift_coins(text, numeric, text) from anon;

-- gifts waiting for me to answer
create or replace function my_pending_gifts() returns json
language plpgsql security definer set search_path = public as $$
declare out json;
begin
  perform _expire_gifts();
  select coalesce(json_agg(json_build_object('id', g.id, 'from', p.username, 'amount', g.amount, 'message', g.message, 'at', g.created_at) order by g.created_at), '[]')
    into out from gifts g join profiles p on p.id = g.from_id
   where g.to_id = auth.uid() and g.status = 'pending';
  return out;
end $$;

-- accept (coins to me) or decline (coins back to the sender)
create or replace function answer_gift(p_id uuid, p_accept boolean) returns json
language plpgsql security definer set search_path = public as $$
declare g gifts; bal numeric;
begin
  select * into g from gifts where id = p_id and to_id = auth.uid() for update;
  if not found then raise exception 'Gift not found'; end if;
  if g.status <> 'pending' then raise exception 'That gift was already %', g.status; end if;
  if p_accept then
    update profiles set balance = balance + g.amount where id = auth.uid() returning balance into bal;
    update gifts set status = 'accepted', answered_at = now(), seen = true where id = g.id;
  else
    update profiles set balance = balance + g.amount where id = g.from_id;
    update gifts set status = 'declined', answered_at = now(), seen = true where id = g.id;
    select balance into bal from profiles where id = auth.uid();
  end if;
  return json_build_object('balance', bal, 'accepted', p_accept, 'amount', g.amount);
end $$;

-- senders hear back when their gift is declined or expires
create or replace function my_gift_replies() returns json
language plpgsql security definer set search_path = public as $$
declare out json;
begin
  perform _expire_gifts();
  select coalesce(json_agg(json_build_object('to', p.username, 'amount', g.amount, 'status', g.status) order by g.answered_at), '[]')
    into out from gifts g join profiles p on p.id = g.to_id
   where g.from_id = auth.uid() and g.status in ('accepted', 'declined', 'expired')
     and g.answered_at > now() - interval '7 days' and not coalesce(g.sender_seen, false);
  update gifts set sender_seen = true where from_id = auth.uid() and status in ('accepted', 'declined', 'expired') and not coalesce(sender_seen, false);
  return out;
end $$;

notify pgrst, 'reload schema';

-- ================= Rebirth cost 100k +50k =================
create or replace function _rebirth_cost(p_done int) returns numeric
language sql immutable as $$ select 100000::numeric + 50000 * coalesce(p_done, 0) $$;
notify pgrst, 'reload schema';

-- ================= Leaderboard banned can't gift =================
create or replace function gift_coins(p_to text, p_amount numeric, p_message text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  bal numeric;
  them_name text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if (select banned from profiles where id = me) then raise exception 'Your account is banned'; end if;
  if (select board_hidden from profiles where id = me) then raise exception 'Leaderboard banned players can''t send gifts'; end if;
  p_amount := round(p_amount, 2);
  p_message := nullif(left(trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')), 80), '');
  if p_amount is null or p_amount <= 0 or p_amount <> p_amount then raise exception 'Invalid amount'; end if;

  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_to)) and not banned and approved order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_to; end if;
  if them = me then raise exception 'You can''t gift yourself'; end if;

  perform 1 from profiles where id = me for update;
  if gifts_left() <= 0 then raise exception 'You''ve used all 10 gifts for today. Resets at midnight.'; end if;
  select balance into bal from profiles where id = me;
  if bal - p_amount < 1000 then
    raise exception 'You can only gift coins above 1,000 (you can send %)', greatest(0, bal - 1000);
  end if;

  update profiles set balance = balance - p_amount where id = me returning balance into bal;
  insert into gifts (from_id, to_id, amount, message, status) values (me, them, p_amount, p_message, 'pending');
  return json_build_object('balance', bal, 'to', them_name, 'amount', p_amount, 'left', gifts_left(), 'pending', true);
end $$;
revoke execute on function gift_coins(text, numeric, text) from anon;

notify pgrst, 'reload schema';

-- ================= Owner-only notice =================
create or replace function _owner_only_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.text is distinct from old.text and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can change the site notice';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_notice on site_notice;
create trigger owner_only_notice before update on site_notice
for each row execute function _owner_only_notice();

-- ================= 1v1 history =================
create or replace function pvp_history() returns json
language sql stable security definer set search_path = public as $$
  with mine as (
    select m.*, case when m.a = auth.uid() then m.b else m.a end as opp_id,
           case when m.winner is null then 'tie' when m.winner = auth.uid() then 'win' else 'lose' end as outcome
    from pvp_matches m
    where (m.a = auth.uid() or m.b = auth.uid()) and m.status = 'done'
  )
  select json_build_object(
    'wins',   (select count(*) from mine where outcome = 'win'),
    'losses', (select count(*) from mine where outcome = 'lose'),
    'ties',   (select count(*) from mine where outcome = 'tie'),
    'net',    (select coalesce(sum(case when friendly then 0 when outcome = 'win' then stake when outcome = 'lose' then -stake else 0 end), 0) from mine),
    'recent', (select coalesce(json_agg(r order by r.at desc), '[]') from (
                 select x.created_at as at, p.username as opp, x.friendly, x.stake, x.outcome
                 from mine x join profiles p on p.id = x.opp_id
                 order by x.created_at desc limit 8) r)
  )
$$;
revoke execute on function pvp_history() from anon;
notify pgrst, 'reload schema';

-- ========== Mines ==========
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

-- ========== Mines: high risk high reward ==========
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

-- ========== Mines: max win 20m ==========
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

-- ========== Roulette ==========
-- Jambling: Roulette (European, single 0). Run once in Supabase > SQL Editor.
-- Bets: red/black, odd/even, 1-18/19-36 pay 1:1, dozens pay 2:1, a single number pays 35:1.
-- Max bet 100k, max win 5m. Bad luck = always loses. Rush hour = a losing spin gets one free re-spin.

create table if not exists roulette_spins (
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null, kind text not null, num int, result int not null,
  payout numeric not null, created_at timestamptz not null default now()
);
create index if not exists roulette_spins_user on roulette_spins (user_id, created_at desc);
alter table roulette_spins enable row level security;   -- no policies: only functions touch it

create or replace function _roulette_win(kind text, num int, r int) returns int   -- profit multiple, 0 = lose
language sql immutable as $$
  select case
    when kind = 'number' then case when r = num then 35 else 0 end
    when r = 0 then 0
    when kind = 'red'   then case when r = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 1 else 0 end
    when kind = 'black' then case when not r = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 1 else 0 end
    when kind = 'odd'   then case when r % 2 = 1 then 1 else 0 end
    when kind = 'even'  then case when r % 2 = 0 then 1 else 0 end
    when kind = 'low'   then case when r <= 18 then 1 else 0 end
    when kind = 'high'  then case when r >= 19 then 1 else 0 end
    when kind = 'dozen1' then case when r <= 12 then 2 else 0 end
    when kind = 'dozen2' then case when r between 13 and 24 then 2 else 0 end
    when kind = 'dozen3' then case when r >= 25 then 2 else 0 end
    else 0 end
$$;

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
  if p_kind not in ('red','black','odd','even','low','high','dozen1','dozen2','dozen3','number') then raise exception 'Pick a bet'; end if;
  if p_kind = 'number' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number 0-36'; end if;
  if p_kind <> 'number' then p_num := null; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  r := floor(random() * 37)::int;
  if _bad_luck_now(auth.uid()) then
    -- bad luck: land on a losing pocket
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  elsif _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then
    r := floor(random() * 37)::int;   -- rush hour: one free re-spin on a loss
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

-- your last 12 results (for the history strip)
create or replace function roulette_recent() returns int[]
language sql stable security definer set search_path = public as $$
  select coalesce(array(select result from roulette_spins where user_id = auth.uid() order by id desc limit 12), '{}')
$$;

notify pgrst, 'reload schema';

-- ========== Mines: max 15 bombs ==========
-- Jambling: Mines max 15 bombs. Run once in Supabase > SQL Editor (after mines_all.sql).

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
  if p_mines is null or p_mines < 1 or p_mines > 15 then raise exception 'Pick 1 to 15 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Roulette boost + Rocket removed ==========
-- Jambling: boost (good luck) on Roulette + remove Rocket. Run once in Supabase > SQL Editor (after roulette.sql).
-- Roulette effects:  bad luck = always loses.  Rush hour = a losing spin gets 1 free re-spin.
--                    Boost (good luck) = a losing spin gets 1 free re-spin (stacks with rush hour: up to 2).
-- Mines effects (already in): bad luck = every tile is a bomb. Rush hour and boost each halve the bomb chance.

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
  if p_kind not in ('red','black','odd','even','low','high','dozen1','dozen2','dozen3','number') then raise exception 'Pick a bet'; end if;
  if p_kind = 'number' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number 0-36'; end if;
  if p_kind <> 'number' then p_num := null; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  r := floor(random() * 37)::int;
  if _bad_luck_now(auth.uid()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  else
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp())
       and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

-- Rocket removed: no new rounds (anyone mid-round can still cash out)
create or replace function crash_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Rocket was removed. Refresh the page.';
end $$;

notify pgrst, 'reload schema';

-- ========== 1v1 Shadow Boxing (replaces blackjack) ==========
-- Jambling: turn 1v1 into Shadow Boxing. Run once in Supabase > SQL Editor.
-- Both players secretly pick a move each round; the server only resolves once BOTH are in,
-- so reaction time and lag never matter (no unfair advantage). First to drop the other to 0 HP wins.
--
-- Moves (damage you deal, by your move vs theirs):
--   JAB   fast poke   vs JAB 6,  vs HOOK 14, vs BLOCK 0,  vs DODGE 10   (interrupts hooks, tracks dodges)
--   HOOK  heavy swing vs JAB 0,  vs HOOK 18, vs BLOCK 16, vs DODGE 0    (smashes guards, whiffs vs jab/dodge)
--   BLOCK guard       deals 0, but fully stops a JAB (take 0)           (loses to HOOK)
--   DODGE slip        deals 0, except a 12 COUNTER when they HOOK        (loses to JAB)
-- Rock-paper-scissors: BLOCK beats JAB, HOOK beats BLOCK, JAB/DODGE beat HOOK, JAB beats DODGE.

alter table pvp_matches add column if not exists a_hp int not null default 100;
alter table pvp_matches add column if not exists b_hp int not null default 100;
alter table pvp_matches add column if not exists a_move text;
alter table pvp_matches add column if not exists b_move text;
alter table pvp_matches add column if not exists round int not null default 1;
alter table pvp_matches add column if not exists log jsonb not null default '[]';

-- any boxing match still stuck on the old blackjack code: void it so nobody is frozen
update pvp_matches set status = 'done', result = 'tie', winner = null
 where status = 'live' and a_hp = 100 and b_hp = 100 and (a_cards <> '{}' or b_cards <> '{}') and round = 1 and a_move is null and b_move is null;

create or replace function _box_dmg(mine text, theirs text) returns int
language sql immutable as $$
  select case mine
    when 'jab'   then case theirs when 'jab' then 6  when 'hook' then 14 when 'block' then 0  when 'dodge' then 10 else 0 end
    when 'hook'  then case theirs when 'jab' then 0  when 'hook' then 18 when 'block' then 16 when 'dodge' then 0  else 0 end
    when 'dodge' then case theirs when 'hook' then 12 else 0 end
    else 0 end
$$;

-- decide a finished boxing match by HP and pay out (internal)
create or replace function _pvp_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; w uuid; res text;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' then return; end if;
  -- fight ends on a KO or at the round cap (25)
  if m.a_hp > 0 and m.b_hp > 0 and m.round <= 25 then return; end if;
  if m.a_hp = m.b_hp then w := null; res := 'tie';
  elsif m.a_hp > m.b_hp then w := m.a; res := 'win';
  else w := m.b; res := 'win'; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
end $$;

-- once both moves are in for the round, resolve it (internal)
create or replace function _box_resolve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; da int; db int; na int; nb int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or m.a_move is null or m.b_move is null then return; end if;
  db := _box_dmg(m.a_move, m.b_move);   -- damage a deals to b
  da := _box_dmg(m.b_move, m.a_move);   -- damage b deals to a
  na := greatest(0, m.a_hp - da);
  nb := greatest(0, m.b_hp - db);
  update pvp_matches set
    a_hp = na, b_hp = nb,
    log = log || jsonb_build_object('round', m.round, 'am', m.a_move, 'bm', m.b_move, 'ad', db, 'bd', da, 'ahp', na, 'bhp', nb),
    round = m.round + 1, a_move = null, b_move = null, a_acted = now(), b_acted = now()
   where id = m.id;
  perform _pvp_settle(m.id);
end $$;
revoke execute on function _box_dmg(text, text) from public, anon, authenticated;
revoke execute on function _box_resolve(uuid) from public, anon, authenticated;
revoke execute on function _pvp_settle(uuid) from public, anon, authenticated;

-- housekeeping: expire old challenges; if a player sits on a move for 75s, auto-BLOCK so matches never hang
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
    if m.a_move is null and m.a_acted < now() - interval '75 seconds' then update pvp_matches set a_move = 'block' where id = m.id; end if;
    if m.b_move is null and m.b_acted < now() - interval '75 seconds' then update pvp_matches set b_move = 'block' where id = m.id; end if;
    perform _box_resolve(m.id);
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- what one player is allowed to see (never the opponent's move until the round resolves)
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me;
begin
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round,
    'my_hp', case when is_a then m.a_hp else m.b_hp end,
    'opp_hp', case when is_a then m.b_hp else m.a_hp end,
    'my_move', case when is_a then m.a_move else m.b_move end,          -- what I locked in (null = not yet)
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- accept a challenge: start the fight at 100 HP each
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
  update pvp_matches set status = 'live', a_hp = 100, b_hp = 100, round = 1,
         a_move = null, b_move = null, log = '[]', a_acted = now(), b_acted = now()
   where id = m.id;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- lock in your move for the current round
create or replace function pvp_box(p_id uuid, p_move text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean;
begin
  if p_move not in ('jab','hook','block','dodge') then raise exception 'Bad move'; end if;
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' then raise exception 'No match in play'; end if;
  is_a := m.a = me;
  if (is_a and m.a_move is not null) or (not is_a and m.b_move is not null) then
    raise exception 'You already moved. Waiting on your opponent.';
  end if;
  if is_a then update pvp_matches set a_move = p_move, a_acted = now() where id = m.id;
  else update pvp_matches set b_move = p_move, b_acted = now() where id = m.id; end if;
  perform _box_resolve(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- old blackjack move function is gone
create or replace function pvp_move(p_id uuid, p_hit boolean) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception '1v1 is now Shadow Boxing. Refresh the page.'; end $$;

notify pgrst, 'reload schema';

-- ========== 1v1 juke/prediction duel (replaces boxing) ==========
-- Jambling: make 1v1 a prediction/juke duel. Run once in Supabase > SQL Editor (after boxing.sql, or on its own).
-- One player ATTACKS, the other DODGES. Both secretly pick a side (Up/Down/Left/Right) at the same time,
-- resolved only once BOTH are in, so reaction time and lag never matter.
--   Same side  -> the attacker read you: HIT, their streak +1.
--   Different   -> you dodged: it becomes YOUR turn to attack (no point), their streak resets.
-- First to land 3 hits in a row wins. You can't pick the same side twice in a row.

alter table pvp_matches add column if not exists attacker uuid;
alter table pvp_matches add column if not exists streak int not null default 0;
alter table pvp_matches add column if not exists a_last text;
alter table pvp_matches add column if not exists b_last text;

-- pay out and close a finished duel (internal)
create or replace function _pvp_finish(p_id uuid, w uuid, res text) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' then return; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
end $$;

-- kept for the round-cap path
create or replace function _pvp_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or m.round <= 40 then return; end if;
  perform _pvp_finish(p_id, null, 'tie');   -- 40 exchanges with nobody reaching 3 in a row = draw
end $$;

-- resolve one exchange once both picks are in (internal)
create or replace function _box_resolve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; hit boolean; new_atk uuid; new_streak int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or m.a_move is null or m.b_move is null then return; end if;
  hit := m.a_move = m.b_move;                          -- attacker guessed the same side = landed
  if hit then new_atk := m.attacker; new_streak := m.streak + 1;
  else new_atk := case when m.attacker = m.a then m.b else m.a end; new_streak := 0;   -- dodged: turn flips
  end if;
  update pvp_matches set
    log = log || jsonb_build_object('round', m.round, 'am', m.a_move, 'bm', m.b_move,
                   'atk', case when m.attacker = m.a then 'a' else 'b' end, 'hit', hit, 'streak', new_streak),
    attacker = new_atk, streak = new_streak,
    a_last = m.a_move, b_last = m.b_move, a_move = null, b_move = null,
    round = m.round + 1, a_acted = now(), b_acted = now()
   where id = m.id;
  if hit and new_streak >= 3 then perform _pvp_finish(p_id, m.attacker, 'win');
  else perform _pvp_settle(p_id); end if;
end $$;
revoke execute on function _pvp_finish(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function _pvp_settle(uuid) from public, anon, authenticated;
revoke execute on function _box_resolve(uuid) from public, anon, authenticated;

-- housekeeping: expire old challenges; if a player sits 75s, auto-pick a random legal side so matches never hang
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; dirs text[] := array['up','down','left','right']; pick text;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.a_move is null and m.a_acted < now() - interval '75 seconds' then
      select d into pick from unnest(dirs) d where d is distinct from m.a_last order by random() limit 1;
      update pvp_matches set a_move = pick where id = m.id;
    end if;
    if m.b_move is null and m.b_acted < now() - interval '75 seconds' then
      select d into pick from unnest(dirs) d where d is distinct from m.b_last order by random() limit 1;
      update pvp_matches set b_move = pick where id = m.id;
    end if;
    perform _box_resolve(m.id);
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- what one player may see (never the opponent's pick until the exchange resolves)
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me;
begin
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round, 'streak', m.streak,
    'attacking', m.attacker = me,
    'my_move', case when is_a then m.a_move else m.b_move end,
    'my_last', case when is_a then m.a_last else m.b_last end,
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- accept: challenger (a) attacks first
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
  update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
         a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
   where id = m.id;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- lock in your side for this exchange (can't repeat your own last side)
create or replace function pvp_pick(p_id uuid, p_dir text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; mylast text;
begin
  if p_dir not in ('up','down','left','right') then raise exception 'Bad move'; end if;
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' then raise exception 'No match in play'; end if;
  is_a := m.a = me;
  if (is_a and m.a_move is not null) or (not is_a and m.b_move is not null) then
    raise exception 'You already picked. Waiting on your opponent.';
  end if;
  mylast := case when is_a then m.a_last else m.b_last end;
  if p_dir = mylast then raise exception 'You can''t pick the same side twice in a row'; end if;
  if is_a then update pvp_matches set a_move = p_dir, a_acted = now() where id = m.id;
  else update pvp_matches set b_move = p_dir, b_acted = now() where id = m.id; end if;
  perform _box_resolve(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- old move functions are gone
create or replace function pvp_box(p_id uuid, p_move text) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception '1v1 was updated. Refresh the page.'; end $$;
create or replace function pvp_move(p_id uuid, p_hit boolean) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception '1v1 was updated. Refresh the page.'; end $$;

notify pgrst, 'reload schema';

-- ========== 1v1 Filler mode ==========
-- Jambling: add Filler as a second 1v1 mode. Run once in Supabase > SQL Editor (after duel.sql).
-- Filler: 7x6 board of 6 colors. You own bottom-left, opponent owns top-right. Take turns picking a
-- color (not your current or your opponent's current); your blob becomes that color and absorbs any
-- touching tiles of it. When the board fills, most tiles wins. Turn-based, pure strategy, no luck.

alter table pvp_matches add column if not exists game text not null default 'duel';
alter table pvp_matches add column if not exists fb int[];     -- board colors, row-major, length 42
alter table pvp_matches add column if not exists fo int[];     -- owner per tile: 0 neutral, 1 = player a, 2 = player b
alter table pvp_matches add column if not exists fturn uuid;   -- whose move

-- flood: set player p's blob to color k, then absorb neutral touching tiles of color k (7 rows x 6 cols)
create or replace function _filler_apply(board int[], own int[], p int, k int, out ob int[], out oo int[])
language plpgsql immutable as $$
declare cols int := 6; rows int := 7; i int; rr int; cc int; changed boolean; n int;
begin
  ob := board; oo := own;
  for i in 1..42 loop if oo[i] = p then ob[i] := k; end if; end loop;
  loop
    changed := false;
    for i in 1..42 loop
      if oo[i] = 0 and ob[i] = k then
        rr := (i - 1) / cols; cc := (i - 1) % cols;
        foreach n in array array[
          case when rr > 0 then i - cols end, case when rr < rows-1 then i + cols end,
          case when cc > 0 then i - 1 end, case when cc < cols-1 then i + 1 end] loop
          if n is not null and oo[n] = p then oo[i] := p; changed := true; exit; end if;
        end loop;
      end if;
    end loop;
    exit when not changed;
  end loop;
end $$;

create or replace function _filler_color(board int[], own int[], p int) returns int
language sql immutable as $$ select (select board[i] from generate_series(1,42) i where own[i] = p limit 1) $$;

create or replace function _filler_count(own int[], p int) returns int
language sql immutable as $$ select count(*)::int from generate_series(1,42) i where own[i] = p $$;

-- start a filler board: random colors, corners must differ
create or replace function _filler_start() returns int[]
language plpgsql volatile as $$
declare b int[];
begin
  loop
    select array_agg(floor(random()*6)::int) into b from generate_series(1,42);
    exit when b[37] <> b[6];   -- bottom-left (index 37) vs top-right (index 6)
  end loop;
  return b;
end $$;
revoke execute on function _filler_apply(int[],int[],int,int) from public, anon, authenticated;
revoke execute on function _filler_color(int[],int[],int) from public, anon, authenticated;
revoke execute on function _filler_count(int[],int) from public, anon, authenticated;
revoke execute on function _filler_start() from public, anon, authenticated;

create or replace function pvp_fill(p_id uuid, p_color int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; p int; nbd int[]; nown int[]; na int; nb int; w uuid; r text;
begin
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'filler' then raise exception 'No match in play'; end if;
  if m.fturn <> me then raise exception 'Not your turn'; end if;
  if p_color < 0 or p_color > 5 then raise exception 'Bad color'; end if;
  p := case when m.a = me then 1 else 2 end;
  if p_color = _filler_color(m.fb, m.fo, 1) or p_color = _filler_color(m.fb, m.fo, 2) then
    raise exception 'That color is in play';
  end if;
  select ob, oo into nbd, nown from _filler_apply(m.fb, m.fo, p, p_color);
  na := _filler_count(nown, 1); nb := _filler_count(nown, 2);
  if na + nb >= 42 then
    if na = nb then w := null; r := 'tie'; elsif na > nb then w := m.a; r := 'win'; else w := m.b; r := 'win'; end if;
    if not m.friendly then
      if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
      else update profiles set balance = balance + m.stake * 2 where id = w; end if;
    end if;
    update pvp_matches set fb = nbd, fo = nown, status = 'done', winner = w, result = r where id = m.id;
  else
    update pvp_matches set fb = nbd, fo = nown, fturn = case when m.a = me then m.b else m.a end,
           a_acted = now(), b_acted = now() where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

notify pgrst, 'reload schema';

-- challenge now carries a game type
create or replace function pvp_challenge(p_user text, p_stake numeric, p_friendly boolean, p_game text default 'duel') returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); them uuid; bal numeric; m pvp_matches;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_game not in ('duel','filler') then p_game := 'duel'; end if;
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

-- accept: branch on game
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
  else
    update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
           a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
     where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- view: duel fields OR filler fields depending on game
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end;
begin
  if m.game = 'filler' then
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'filler', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'board', m.fb, 'owner', m.fo, 'me_p', p,
      'my_turn', m.fturn = me,
      'my_color', _filler_color(m.fb, m.fo, p), 'opp_color', _filler_color(m.fb, m.fo, 3 - p),
      'my_count', _filler_count(m.fo, p), 'opp_count', _filler_count(m.fo, 3 - p),
      'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
      'balance', (select balance from profiles where id = me));
  end if;
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'duel', 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round, 'streak', m.streak, 'attacking', m.attacker = me,
    'my_move', case when is_a then m.a_move else m.b_move end,
    'my_last', case when is_a then m.a_last else m.b_last end,
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- housekeeping: expire old challenges; auto-move idle players in both games (90s)
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; dirs text[] := array['up','down','left','right']; pick text; k int; idle uuid;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.game = 'filler' then
      idle := case when m.fturn = m.a and m.a_acted < now() - interval '90 seconds' then m.a
                   when m.fturn = m.b and m.b_acted < now() - interval '90 seconds' then m.b end;
      if idle is not null then
        select c into k from generate_series(0,5) c
          where c <> _filler_color(m.fb, m.fo, 1) and c <> _filler_color(m.fb, m.fo, 2) order by random() limit 1;
        declare nbd int[]; nown int[]; na int; nb int; w uuid; r text;
        begin
          select ob, oo into nbd, nown from _filler_apply(m.fb, m.fo, case when idle = m.a then 1 else 2 end, k);
          na := _filler_count(nown,1); nb := _filler_count(nown,2);
          if na + nb >= 42 then
            if na = nb then w := null; r := 'tie'; elsif na > nb then w := m.a; r := 'win'; else w := m.b; r := 'win'; end if;
            if not m.friendly then
              if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
              else update profiles set balance = balance + m.stake * 2 where id = w; end if;
            end if;
            update pvp_matches set fb = nbd, fo = nown, status='done', winner=w, result=r where id = m.id;
          else
            update pvp_matches set fb = nbd, fo = nown, fturn = case when idle = m.a then m.b else m.a end,
                   a_acted = now(), b_acted = now() where id = m.id;
          end if;
        end;
      end if;
    else
      if m.a_move is null and m.a_acted < now() - interval '75 seconds' then
        select d into pick from unnest(dirs) d where d is distinct from m.a_last order by random() limit 1;
        update pvp_matches set a_move = pick where id = m.id;
      end if;
      if m.b_move is null and m.b_acted < now() - interval '75 seconds' then
        select d into pick from unnest(dirs) d where d is distinct from m.b_last order by random() limit 1;
        update pvp_matches set b_move = pick where id = m.id;
      end if;
      perform _box_resolve(m.id);
    end if;
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- pvp_state: include the game type in the challenge lists
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

notify pgrst, 'reload schema';

-- ========== Give rebirths (owner only) ==========
-- Jambling: give rebirths (owner only - just max). Run once in Supabase > SQL Editor.
create or replace function admin_give_rebirths(p_user text, p_n int) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; rb int;
begin
  if not am_owner() then raise exception 'Only max can give rebirths'; end if;
  if p_n is null or p_n <= 0 then raise exception 'Enter how many'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set rebirths = rebirths + p_n where id = them returning rebirths into rb;
  return json_build_object('user', them_name, 'rebirths', rb);
end $$;
revoke execute on function admin_give_rebirths(text, int) from anon;

notify pgrst, 'reload schema';

-- ========== Roulette & Mines bet 1m, Mines 18 bombs ==========
-- Jambling: Roulette & Mines max bet 1,000,000; Mines max 18 bombs. Run once in Supabase > SQL Editor.

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
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 18 then raise exception 'Pick 1 to 18 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
  if p_kind not in ('red','black','odd','even','low','high','dozen1','dozen2','dozen3','number') then raise exception 'Pick a bet'; end if;
  if p_kind = 'number' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number 0-36'; end if;
  if p_kind <> 'number' then p_num := null; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  r := floor(random() * 37)::int;
  if _bad_luck_now(auth.uid()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  else
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp())
       and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Rebirth luck 5%; Mines back to 15 ==========
-- Jambling: rebirth luck +5% per rebirth (was 10%); Mines back to 15 max bombs. Run once in Supabase > SQL Editor.
-- Applies immediately to everyone (luck is computed live from the rebirth count).

create or replace function _luck(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select 1 + 0.05 * coalesce((select rebirths from profiles where id = p_uid), 0)
$$;

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
  luck := 1 + 0.05 * coalesce((select rebirths from profiles where id = h.user_id), 0);
  pay := case res
    when 'blackjack' then round(h.bet + h.bet * 1.5 * luck, 2)
    when 'win'       then round(h.bet + h.bet * luck, 2)
    when 'push'      then h.bet
    else 0 end;
  pay := least(pay, h.bet + 5000000);   -- max win 5m per hand
  update bj_hands set dealer = h.dealer, deck = h.deck, status = 'done', result = res, payout = pay where id = h.id
    returning * into h;
  update profiles set balance = balance + pay where id = h.user_id;
  return h;
end $$;

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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 5000000);                         -- max win 5m per round (RIDE_MAX_WIN in index.html)
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

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
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 15 then raise exception 'Pick 1 to 15 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

notify pgrst, 'reload schema';

-- ========== Ride: bet 1m, profit 10m, 20% rugs, more pumps ==========
-- Jambling: Ride max bet 1m, profit cap 10m, 20%% rug-pulls on pumps, and more pumps.
-- Run once in Supabase > SQL Editor.

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
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;

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
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.97 else 0.985 end) then
      if u2 < (case when i <= p_rush then 0.88 else 0.60 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.20 then
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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 10000000);                         -- max win 10m per round (RIDE_MAX_WIN in index.html)
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';

-- ========== Ride: no profit cap ==========
-- Jambling: Ride profit cap removed (no max win, matches the uncapped bet). Run once in Supabase > SQL Editor.

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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';

-- ========== Ride: no bet cap + bet-scaled rug tiers (synced) ==========
-- Jambling: Ride no bet cap; pumps slightly more common; rug-pull scales with bet (15%% base, 20%% >1m, 25%% >100m, 30%% >1b).
-- Run once in Supabase > SQL Editor.

create or replace function _ride_gen(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0, p_rug float default 0.15,
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
      if u2 < (case when i <= p_rush then 0.88 else 0.52 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < p_rug then
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

create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0, p_rug float default 0.15) returns float8[]
language sql immutable as $$ select (_ride_gen(p_seed, n, p_boost, p_bad, p_rush, p_rug)).px $$;

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                   case when rd.bet > 1000000000 then 0.30 when rd.bet > 100000000 then 0.25 when rd.bet > 1000000 then 0.20 else 0.15 end);
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
    'live', rd.status = 'live');
end $$;

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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                       case when rd.bet > 1000000000 then 0.30 when rd.bet > 100000000 then 0.25 when rd.bet > 1000000 then 0.20 else 0.15 end);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 10000000);                         -- max win 10m per round (RIDE_MAX_WIN in index.html)
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

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

notify pgrst, 'reload schema';

-- ========== Coin 5m; Ride rug tiers 25/30/40 ==========
-- Jambling: Coin Flip max bet 5m; Ride rug tiers 15%% base / 25%% >1m / 30%% >100m / 40%% >1b. Run once in Supabase > SQL Editor.

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
  if p_bet > 5000000 then raise exception 'Max Coin Flip bet is 5,000,000'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip (max bet 1m)

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                   case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
    'live', rd.status = 'live');
end $$;

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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                       case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';

-- ========== Ride: more dumps over 100m ==========
-- Jambling: over-100m bets get a few more dumps on Ride (pump share 46%% vs 52%%). Run once in Supabase > SQL Editor.

create or replace function _ride_gen(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0, p_rug float default 0.15,
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
      if u2 < (case when i <= p_rush then 0.88 else (case when p_rug >= 0.30 then 0.46 else 0.52 end) end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < p_rug then
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

notify pgrst, 'reload schema';

-- ========== Fix bad-luck Ride exploit ==========
-- Jambling: fix bad-luck Ride exploit (crash then recover). Bad luck now curses the whole round and can't profit.
-- Run once in Supabase > SQL Editor.

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

  perform ride_cleanup();

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  select greatest(0, floor(extract(epoch from (boost_until - clock_timestamp())) / 0.1))::int into bs
    from profiles where id = auth.uid() and boost_until > clock_timestamp();
  select greatest(0, floor(extract(epoch from (badluck_until - clock_timestamp())) / 0.1))::int into bad
    from profiles where id = auth.uid() and badluck_until > clock_timestamp();
  if coalesce(bad, 0) > 0 then bad := 1000000000; end if;   -- bad luck curses the whole round, so no crash-and-recover exploit
  select greatest(0, floor(extract(epoch from (rush_until - clock_timestamp())) / 0.1))::int into rush
    from site_state where id = 1 and rush_until > clock_timestamp();
  insert into ride_rounds (user_id, bet, seed, boost_steps, bad_steps, rush_steps)
    values (auth.uid(), p_bet, sd, coalesce(bs, 0), coalesce(bad, 0), coalesce(rush, 0)) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal, 'boost_steps', coalesce(bs, 0), 'bad_steps', coalesce(bad, 0), 'rush_steps', coalesce(rush, 0));
end $$;

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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                       case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard
  if rd.bad_steps > 0 then m := least(m, 1.0); end if;         -- bad luck: never profit

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';

-- ========== Coin Flip no cap, 40% win over 10m ==========
-- Jambling: Coin Flip no bet cap, but bets over 10m secretly win only 40% (60% lose). Run once in Supabase > SQL Editor.
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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

notify pgrst, 'reload schema';

-- ========== Nerf Ride: smaller pumps, 2% hold fee ==========
-- Jambling: nerf Ride - smaller pumps and 2%% hold fee. Run once in Supabase > SQL Editor.

create or replace function _ride_gen(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0, p_rug float default 0.15,
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
      if u2 < (case when i <= p_rush then 0.88 else (case when p_rug >= 0.30 then 0.46 else 0.52 end) end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.3 + 0.35 * (u1 * 53 - floor(u1 * 53)) end;   -- smaller pumps (nerfed)
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < p_rug then
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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                       case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.98 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 2% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard
  if rd.bad_steps > 0 then m := least(m, 1.0); end if;         -- bad luck: never profit

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';

-- ========== Good luck (boost) on Coin Flip + Blackjack ==========
-- Jambling: good luck (boost) now works on Coin Flip and Blackjack too. Run once in Supabase > SQL Editor.

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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- good luck: 80% win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

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
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
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
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then   -- good luck: strong hand, weak dealer
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

notify pgrst, 'reload schema';

-- ========== Good luck = 100% win; rush hour buffed ==========
-- Jambling: good luck = guaranteed win on every house game; rush hour buffed (still not guaranteed). Run once in Supabase > SQL Editor.

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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := p_pick;   -- good luck: always win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.90 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 90% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

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
    if _rush_now() then chance := chance * 0.25; end if;   -- rush hour: quarter the risk
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := 0; end if;   -- good luck: never a bomb
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

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
  if p_kind not in ('red','black','odd','even','low','high','dozen1','dozen2','dozen3','number') then raise exception 'Pick a bet'; end if;
  if p_kind = 'number' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number 0-36'; end if;
  if p_kind <> 'number' then p_num := null; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  r := floor(random() * 37)::int;
  if _bad_luck_now(auth.uid()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  elsif exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) > 0 order by random() limit 1;   -- good luck: always land a winner
  else
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;   -- rush hour: a loss gets two free re-spins
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

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
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
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
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then   -- good luck: player blackjack, dealer can't match
    declare ace int := (select c from unnest(d) c where c % 13 = 0 limit 1);
            ten int := (select c from unnest(d) c where c % 13 >= 9 limit 1);
            w1 int := (select c from unnest(d) c where c % 13 in (3,4,5) limit 1);
            w2 int := (select c from unnest(d) c where c % 13 in (3,4,5) and c <> (select c from unnest(d) c where c % 13 in (3,4,5) limit 1) limit 1);
            picked int[];
    begin
      picked := array[ace, w1, ten, w2];   -- player: ace+ten (blackjack); dealer: two low cards
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by random());
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

notify pgrst, 'reload schema';

-- ========== Owner-only uncapped admin gift ==========
-- Jambling: no gift cap for max (owner); other admins still capped at 1e12. Run once in Supabase > SQL Editor.
create or replace function admin_give(p_user text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; bal numeric;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 then raise exception 'Enter an amount'; end if;
  if not am_owner() and p_amount > 1e12 then raise exception 'Max gift is 1,000,000,000,000'; end if;   -- only max can gift more
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1 for update;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set balance = balance + p_amount where id = them returning balance into bal;
  return json_build_object('user', them_name, 'gave', p_amount, 'balance', bal);
end $$;
revoke execute on function admin_give(text, numeric) from anon;

notify pgrst, 'reload schema';

-- ========== 1v1: 15s move timeout = forfeit ==========
-- Jambling: 1v1 - if you don't move within 15s you lose (forfeit). Run once in Supabase > SQL Editor.

create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; idle uuid;
begin
  -- expire stale challenges (5 min)
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  -- live matches: forfeit a player who hasn't moved in 15 seconds
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.game = 'filler' then
      idle := case when m.fturn = m.a and m.a_acted < now() - interval '15 seconds' then m.a
                   when m.fturn = m.b and m.b_acted < now() - interval '15 seconds' then m.b end;
      if idle is not null then
        perform _pvp_finish(m.id, case when idle = m.a then m.b else m.a end, 'win');   -- idle = you lose
      end if;
    else
      if m.a_move is null and m.a_acted < now() - interval '15 seconds'
         and m.b_move is null and m.b_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, null, 'tie');          -- both idle: draw
      elsif m.a_move is null and m.a_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, m.b, 'win');           -- a idle: a loses
      elsif m.b_move is null and m.b_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, m.a, 'win');           -- b idle: b loses
      else
        perform _box_resolve(m.id);                      -- both moved: resolve the exchange
      end if;
    end if;
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- view: add secs_left (how long until the current player forfeits)
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end; sl numeric;
begin
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

-- ========== Hidden per-player bad luck (rigged): siddthatridegod ==========
-- Jambling: hidden per-player slight bad luck (rigged flag) - applied to siddthatridegod. Run once in Supabase > SQL Editor.

alter table profiles add column if not exists rigged boolean not null default false;
create or replace function _rigged(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rigged from profiles where id = p_uid), false)
$$;
update profiles set rigged = true where lower(username) = 'siddthatridegod';

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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := p_pick;   -- good luck: always win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.90 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 90% win
  else res := case when random() < (case when _rigged(auth.uid()) then 0.44 else 0.5 end) then p_pick when p_pick = 'heads' then 'tails' else 'heads' end; end if;   -- rigged players: 44% win
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

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
    if _rush_now() then chance := chance * 0.25; end if;   -- rush hour: quarter the risk
    if _rigged(auth.uid()) then chance := least(1, chance * 1.2); end if;   -- rigged: a touch more bomb risk
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := 0; end if;   -- good luck: never a bomb
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

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
  if p_kind not in ('red','black','odd','even','low','high','dozen1','dozen2','dozen3','number') then raise exception 'Pick a bet'; end if;
  if p_kind = 'number' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number 0-36'; end if;
  if p_kind <> 'number' then p_num := null; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  r := floor(random() * 37)::int;
  if _bad_luck_now(auth.uid()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  elsif exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) > 0 order by random() limit 1;   -- good luck: always land a winner
  else
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;   -- rush hour: a loss gets two free re-spins
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if _rigged(auth.uid()) and mult > 0 and random() < 0.12 then   -- rigged: quietly turn some wins into losses
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
    mult := 0;
  end if;
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                   least(0.9, (case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end) + case when _rigged(rd.user_id) then 0.07 else 0 end));
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
    'live', rd.status = 'live');
end $$;

notify pgrst, 'reload schema';

-- ========== Shop (rush/boost/steal) ==========
-- Jambling: Shop (rush hour, boost, steal). Run once in Supabase > SQL Editor.

-- let shop purchases pass the owner-only rush/boost guards via a transaction-local flag
create or replace function _owner_only_rush() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.rush_until is distinct from old.rush_until and auth.uid() is not null and not am_owner()
     and coalesce(current_setting('jambling.shop', true), '') <> '1' then
    raise exception 'Only max can start or end rush hour';
  end if;
  return new;
end $$;

create or replace function _owner_only_boost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.boost_until is not null and new.boost_until is distinct from old.boost_until
     and auth.uid() is not null and not am_owner()
     and coalesce(current_setting('jambling.shop', true), '') <> '1' then
    raise exception 'Only max can boost';
  end if;
  return new;
end $$;

-- Rush Hour: 1 quadrillion -> global rush hour for everyone, 30 seconds
create or replace function shop_rush() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e15; bal numeric; until timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 1 quadrillion coins for Rush Hour'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform set_config('jambling.shop', '1', true);
  update site_state set rush_until = greatest(coalesce(rush_until, clock_timestamp()), clock_timestamp()) + interval '30 seconds'
    where id = 1 returning rush_until into until;
  return json_build_object('ok', true, 'balance', bal, 'until', until);
end $$;

-- Boost (good luck): 1 decillon -> buyer gets good luck for 10 seconds
create or replace function shop_boost() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e33; bal numeric; until timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 1 decillion coins for Good Luck'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform set_config('jambling.shop', '1', true);
  update profiles set boost_until = greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '10 seconds'
    where id = auth.uid() returning boost_until into until;
  return json_build_object('ok', true, 'balance', bal, 'until', until);
end $$;

-- Steal: 10 billion fee -> take 5% of a chosen player's coins
create or replace function shop_steal(p_target text) returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e10; me uuid := auth.uid(); them uuid; them_name text; bal numeric; tbal numeric; stolen numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_target)) and approved and not banned order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_target; end if;
  if them = me then raise exception 'You can''t steal from yourself'; end if;
  if exists (select 1 from site_owner where id = them) then raise exception 'You can''t steal from the owner'; end if;
  select balance into bal from profiles where id = me for update;
  if bal < cost then raise exception 'You need 10 billion coins to steal'; end if;
  select balance into tbal from profiles where id = them for update;
  stolen := round(tbal * 0.05, 2);
  update profiles set balance = balance - stolen where id = them;
  update profiles set balance = balance - cost + stolen where id = me returning balance into bal;
  return json_build_object('ok', true, 'balance', bal, 'target', them_name, 'stolen', stolen);
end $$;
revoke execute on function shop_rush() from anon;
revoke execute on function shop_boost() from anon;
revoke execute on function shop_steal(text) from anon;

notify pgrst, 'reload schema';

-- ========== Ride: more but weaker pumps ==========
-- Jambling: Ride - more pumps but weaker. Run once in Supabase > SQL Editor.

create or replace function _ride_gen(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0, p_rug float default 0.15,
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
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.97 else 0.985 end) then
      if u2 < (case when i <= p_rush then 0.88 else (case when p_rug >= 0.30 then 0.46 else 0.52 end) end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.2 + 0.25 * (u1 * 53 - floor(u1 * 53)) end;   -- smaller pumps (nerfed)
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < p_rug then
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

notify pgrst, 'reload schema';

-- ========== Gifted rainbow title (owner only) ==========
-- Jambling: "Gifted" rainbow title, grantable ONLY by max (owner). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists gifted boolean not null default false;

create or replace function admin_gift_title(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the Gifted title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set gifted = p_on where id = them;
  return json_build_object('user', them_name, 'gifted', p_on);
end $$;
revoke execute on function admin_gift_title(text, boolean) from anon;

notify pgrst, 'reload schema';

-- ========== Shop: Poison ==========
-- Jambling: Poison shop item - 10b to drain 1b/sec from the top player for 10 seconds. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists poison_until timestamptz;
alter table profiles add column if not exists poison_tick  timestamptz;

-- lazily drain any poisoned player by the whole seconds elapsed since the last tick (can't be dodged)
create or replace function _settle_poison() returns void
language plpgsql security definer set search_path = public as $$
declare r record; secs int;
begin
  for r in select id, poison_until, poison_tick from profiles where poison_until is not null for update loop
    secs := floor(extract(epoch from least(clock_timestamp(), r.poison_until) - r.poison_tick))::int;
    if secs > 0 then
      update profiles set balance = greatest(0, balance - secs::numeric * 1e9),
             poison_tick = r.poison_tick + (secs || ' seconds')::interval
       where id = r.id;
    end if;
    if clock_timestamp() >= r.poison_until then
      update profiles set poison_until = null, poison_tick = null where id = r.id;
    end if;
  end loop;
end $$;
revoke execute on function _settle_poison() from public, anon, authenticated;

-- buy poison: pay 10b, poison the current richest player (not the owner) for 10s
create or replace function shop_poison() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e10; bal numeric; top uuid; tname text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 10 billion coins for Poison'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform _settle_poison();
  select id, username into top, tname from profiles
   where approved and not banned and not exists (select 1 from site_owner o where o.id = profiles.id)
   order by balance desc limit 1;
  if top is null then raise exception 'No one to poison'; end if;
  update profiles set poison_until = clock_timestamp() + interval '10 seconds', poison_tick = clock_timestamp() where id = top;
  return json_build_object('ok', true, 'balance', bal, 'target', tname);
end $$;
revoke execute on function shop_poison() from anon;

-- client calls this each second to advance the drain
create or replace function poison_pulse() returns json
language plpgsql security definer set search_path = public as $$
begin perform _settle_poison(); return json_build_object('ok', true); end $$;
revoke execute on function poison_pulse() from anon;

notify pgrst, 'reload schema';

-- pvp_state settles poison
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  perform _settle_poison();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

notify pgrst, 'reload schema';

-- ========== Log coin flips ==========
-- Jambling: log every coin flip from now on. Run once in Supabase > SQL Editor.
create table if not exists coin_flips (
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null, pick text not null, result text not null, won boolean not null,
  delta numeric not null, created_at timestamptz not null default now()
);
create index if not exists coin_flips_user on coin_flips (user_id, created_at desc);
alter table coin_flips enable row level security;   -- no policies: only the function writes it

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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := p_pick;   -- good luck: always win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.90 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 90% win
  else res := case when random() < (case when _rigged(auth.uid()) then 0.44 else 0.5 end) then p_pick when p_pick = 'heads' then 'tails' else 'heads' end; end if;   -- rigged players: 44% win
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into coin_flips (user_id, bet, pick, result, won, delta) values (auth.uid(), p_bet, p_pick, res, won, delta);
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

notify pgrst, 'reload schema';

-- ========== Aurora = luck of 100 rebirths ==========
-- Jambling: Aurora grants the luck of 100 rebirths (hidden from counts/titles/leaderboard). Run once in Supabase > SQL Editor.

create or replace function _luck(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select 1 + 0.05 * (coalesce((select rebirths from profiles where id = p_uid), 0)
                     + case when coalesce((select gifted from profiles where id = p_uid), false) then 100 else 0 end)
$$;

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
  luck := _luck(h.user_id);
  pay := case res
    when 'blackjack' then round(h.bet + h.bet * 1.5 * luck, 2)
    when 'win'       then round(h.bet + h.bet * luck, 2)
    when 'push'      then h.bet
    else 0 end;
  pay := least(pay, h.bet + 5000000);   -- max win 5m per hand
  update bj_hands set dealer = h.dealer, deck = h.deck, status = 'done', result = res, payout = pay where id = h.id
    returning * into h;
  update profiles set balance = balance + pay where id = h.user_id;
  return h;
end $$;

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

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                       case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.98 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 2% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard
  if rd.bad_steps > 0 then m := least(m, 1.0); end if;         -- bad luck: never profit

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * _luck(rd.user_id), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';

-- ========== owner_admins ==========
-- Jambling: let ONLY max add/remove admins. Run once in Supabase > SQL Editor.
-- Other admins can't use this (gated on am_owner, not is_admin). The owner (max) can never be removed (existing trigger).

create or replace function owner_set_admin(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can change admins'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if exists (select 1 from site_owner where id = them) then raise exception 'max is always an admin'; end if;
  if p_on then insert into admins values (them) on conflict do nothing;
  else delete from admins where user_id = them; end if;
  return json_build_object('user', them_name, 'admin', p_on);
end $$;
revoke execute on function owner_set_admin(text, boolean) from public, anon;
grant execute on function owner_set_admin(text, boolean) to authenticated;

notify pgrst, 'reload schema';

-- ========== make_laoo_admin ==========
-- Make laoo an admin. Run once in Supabase > SQL Editor.
insert into admins select id from profiles where lower(username) = 'laoo' on conflict do nothing;
-- check it worked (should list laoo):
select username from profiles p join admins a on a.user_id = p.id order by username;

-- ========== tester_title ==========
-- Jambling: new "Tester" title (rainbow outlined, animated) + remove Steal/Poison from the shop.
-- Run once in Supabase > SQL Editor.

-- Tester title: a boolean on profiles, granted by max only (like Aurora).
alter table profiles add column if not exists tester boolean not null default false;

create or replace function admin_gift_tester(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the Tester title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set tester = p_on where id = them;
  return json_build_object('user', them_name, 'tester', p_on);
end $$;
revoke execute on function admin_gift_tester(text, boolean) from anon;
grant execute on function admin_gift_tester(text, boolean) to authenticated;

-- Remove Steal + Poison from the shop: make the RPCs refuse so no old client can still buy them.
create or replace function shop_steal(p_target text) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Steal has been removed from the shop'; end $$;

create or replace function shop_poison() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Poison has been removed from the shop'; end $$;

create or replace function poison_pulse() returns json
language plpgsql security definer set search_path = public as $$
begin return json_build_object('ok', true); end $$;

notify pgrst, 'reload schema';

-- ========== shop_daily ==========
-- Jambling: Good Luck now costs 1 sextillion, and every shop item can be bought once per day (Pacific).
-- max (owner) is exempt from the daily limit. Run once in Supabase > SQL Editor.

create table if not exists shop_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  item text not null,
  at timestamptz not null default now()
);
create index if not exists shop_log_user_day on shop_log (user_id, item, at);
alter table shop_log enable row level security;   -- functions only

-- true if this player already bought p_item today (Pacific). Owner is never limited.
create or replace function _shop_used_today(p_item text) returns boolean
language sql stable security definer set search_path = public as $$
  select not am_owner() and exists (
    select 1 from shop_log
     where user_id = auth.uid() and item = p_item
       and (at at time zone 'America/Los_Angeles')::date = (now() at time zone 'America/Los_Angeles')::date)
$$;
revoke execute on function _shop_used_today(text) from public, anon, authenticated;

create or replace function shop_rush() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e15; bal numeric; until timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if _shop_used_today('rush') then raise exception 'You already bought Rush Hour today. Come back tomorrow.'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 1 quadrillion coins for Rush Hour'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform set_config('jambling.shop', '1', true);
  update site_state set rush_until = greatest(coalesce(rush_until, clock_timestamp()), clock_timestamp()) + interval '30 seconds'
    where id = 1 returning rush_until into until;
  if not am_owner() then insert into shop_log (user_id, item) values (auth.uid(), 'rush'); end if;
  return json_build_object('ok', true, 'balance', bal, 'until', until);
end $$;

-- Good Luck: 1 sextillion -> buyer gets good luck for 10 seconds
create or replace function shop_boost() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e21; bal numeric; until timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if _shop_used_today('boost') then raise exception 'You already bought Good Luck today. Come back tomorrow.'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 1 sextillion coins for Good Luck'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform set_config('jambling.shop', '1', true);
  update profiles set boost_until = greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '10 seconds'
    where id = auth.uid() returning boost_until into until;
  if not am_owner() then insert into shop_log (user_id, item) values (auth.uid(), 'boost'); end if;
  return json_build_object('ok', true, 'balance', bal, 'until', until);
end $$;

revoke execute on function shop_rush() from anon;
revoke execute on function shop_boost() from anon;

notify pgrst, 'reload schema';

-- ========== logs_v2 ==========
-- Jambling: admins can give rebirths + much better staff/gift logging. Run once in Supabase > SQL Editor.
-- (Order-independent: safe to run before or after tester_title.sql / shop_daily.sql.)

-- make sure the tester column exists before the trigger below references it
alter table profiles add column if not exists tester boolean not null default false;

-- 1) Admins (not just max) can give rebirths
create or replace function admin_give_rebirths(p_user text, p_n int) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; rb int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_n is null or p_n <= 0 then raise exception 'Enter how many'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set rebirths = rebirths + p_n where id = them returning rebirths into rb;
  return json_build_object('user', them_name, 'rebirths', rb);
end $$;
revoke execute on function admin_give_rebirths(text, int) from anon;

-- 2) Log role changes (admin/mod promotions + removals) by anyone, so max has a record
create or replace function _watch_roles() returns trigger
language plpgsql security definer set search_path = public as $$
declare uname text; role text := case tg_table_name when 'admins' then 'admin' else 'mod' end;
begin
  if tg_op = 'INSERT' then
    select username into uname from profiles where id = new.user_id;
    perform _log_staff(uname, 'made ' || case when role = 'admin' then 'an admin' else 'a mod' end);
    return new;
  else
    select username into uname from profiles where id = old.user_id;
    perform _log_staff(uname, 'removed as ' || role);
    return old;
  end if;
end $$;
drop trigger if exists watch_admins on admins;
create trigger watch_admins after insert or delete on admins for each row execute function _watch_roles();
drop trigger if exists watch_mods on moderators;
create trigger watch_mods after insert or delete on moderators for each row execute function _watch_roles();

-- 3) Rewrite the profiles watcher: log title grants + leaderboard hides too, title changes by ANYONE (incl. max)
create or replace function _watch_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text[] := '{}'; actor uuid := auth.uid();
begin
  if tg_op = 'DELETE' then
    if _is_staff_not_owner() and old.id <> actor then
      perform _log_staff(old.username, 'deleted the account (had ' || to_char(old.balance, 'FM999,999,999,999,990') || ' coins)');
    end if;
    return old;
  end if;

  -- title grants: recorded no matter who does them (these are max-only, but max wants to see them)
  if new.id is distinct from actor then
    if new.gifted is distinct from old.gifted then
      perform _log_staff(new.username, case when new.gifted then 'granted the Aurora title' else 'removed the Aurora title' end);
    end if;
    if new.tester is distinct from old.tester then
      perform _log_staff(new.username, case when new.tester then 'granted the Tester title' else 'removed the Tester title' end);
    end if;
  end if;

  -- everything else: only non-owner admins/mods acting on someone else
  if not _is_staff_not_owner() or new.id = actor then return new; end if;
  if new.balance > old.balance then w := w || ('gave ' || to_char(new.balance - old.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.balance < old.balance then w := w || ('took ' || to_char(old.balance - new.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.username is distinct from old.username then w := w || ('renamed ' || old.username || ' -> ' || new.username); end if;
  if new.rebirths is distinct from old.rebirths then
    w := w || ((case when new.rebirths > old.rebirths then 'gave ' || (new.rebirths - old.rebirths) || ' rebirths'
                     else 'took ' || (old.rebirths - new.rebirths) || ' rebirths' end) || ' (now ' || new.rebirths || ')');
  end if;
  if new.badluck_until is distinct from old.badluck_until then
    w := w || (case when new.badluck_until is null or new.badluck_until < now() then 'removed bad luck' else 'gave bad luck' end);
  end if;
  if new.boost_until is distinct from old.boost_until and new.boost_until is null then w := w || 'removed boost'::text; end if;
  if new.board_hidden is distinct from old.board_hidden then w := w || (case when new.board_hidden then 'hid from leaderboard' else 'unhid from leaderboard' end); end if;
  if new.approved is distinct from old.approved then w := w || (case when new.approved then 'accepted from waiting room' else 'sent to waiting room' end); end if;
  if new.rejected_at is distinct from old.rejected_at and new.rejected_at is not null then w := w || 'rejected from waiting room'::text; end if;
  if array_length(w, 1) > 0 then perform _log_staff(new.username, array_to_string(w, ', ')); end if;
  return new;
end $$;
drop trigger if exists watch_profiles on profiles;
create trigger watch_profiles after update or delete on profiles for each row execute function _watch_profiles();

-- 4) Gift log: also return a running total so the client can show a summary
drop function if exists admin_gift_log(text);
create or replace function admin_gift_log(p_user text default null) returns table(at timestamptz, from_user text, to_user text, amount numeric, message text, total numeric, cnt bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    with rows as (
      select g.created_at, f.username as fu, t.username as tu, g.amount as amt, g.message as msg
      from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
      where coalesce(trim(p_user), '') = ''
         or lower(f.username) = lower(trim(p_user)) or lower(t.username) = lower(trim(p_user)))
    select r.created_at, r.fu, r.tu, r.amt, r.msg,
           sum(r.amt) over (), count(*) over ()
    from rows r order by r.created_at desc limit 200;
end $$;
revoke execute on function admin_gift_log(text) from anon;

notify pgrst, 'reload schema';

-- ========== remove_shop ==========
-- Jambling: shop removed. Make the shop RPCs refuse so nobody can call them with the anon key. Run once.
create or replace function shop_rush() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'The shop has been removed'; end $$;

create or replace function shop_boost() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'The shop has been removed'; end $$;

notify pgrst, 'reload schema';

-- ========== single_role ==========
-- Jambling: a player can't be admin and mod at the same time. Run once in Supabase > SQL Editor.
-- Making someone an admin drops their mod role; making someone a mod drops their admin role. The owner stays admin.

create or replace function _one_role_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'admins' then
    delete from moderators where user_id = new.user_id;       -- admin supersedes mod
  else
    if exists (select 1 from site_owner where id = new.user_id) then
      raise exception 'The owner is always an admin, not a mod';
    end if;
    delete from admins where user_id = new.user_id;           -- mod drops admin
  end if;
  return new;
end $$;

drop trigger if exists one_role_admins on admins;
create trigger one_role_admins before insert on admins for each row execute function _one_role_only();
drop trigger if exists one_role_mods on moderators;
create trigger one_role_mods before insert on moderators for each row execute function _one_role_only();

-- clean up anyone who is currently both (admin wins)
delete from moderators where user_id in (select user_id from admins);

notify pgrst, 'reload schema';

-- ========== demote_bebewill ==========
-- Demote Bebewill from admin to mod. Run once in Supabase > SQL Editor.
-- (Works with or without single_role.sql: it removes admin and adds mod explicitly.)
do $$
declare uid uuid;
begin
  select id into uid from profiles where lower(username) = 'bebewill' order by created_at limit 1;
  if uid is null then raise exception 'No player named Bebewill'; end if;
  delete from admins where user_id = uid;
  insert into moderators (user_id) values (uid) on conflict do nothing;
end $$;

-- confirm (should show bebewill as mod only):
select p.username, 'admin' as role from admins a join profiles p on p.id = a.user_id where lower(p.username) = 'bebewill'
union all
select p.username, 'mod' from moderators m join profiles p on p.id = m.user_id where lower(p.username) = 'bebewill';

-- ========== restore_rocket ==========
-- Jambling: bring Rocket back and make it respect every effect. Run once in Supabase > SQL Editor.
--   Bad luck  -> crashes instantly (you lose)
--   Good luck -> flies to 1000x, so any cash-out is a win
--   Rush hour -> much higher crash points (1.8x floor, ~7x typical)
--   Rebirths  -> multiply your winnings (via _luck, applied on cash-out)

create or replace function crash_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; cp numeric; rid uuid; r float8;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then
    cp := 1.00;                                                        -- bad luck: blows up instantly
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then
    cp := 1000;                                                        -- good luck: flies high, any cash-out wins
  elsif _rush_now() then
    r := random();
    cp := least(1000, greatest(1.8, floor(3.5 / (1 - r) * 100) / 100))::numeric;   -- rush hour: 1.8x floor, ~7x typical
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric; -- normal
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal);
end $$;
revoke execute on function crash_start(numeric) from anon;

-- cash-out: winnings scale with rebirths (_luck), capped at +5m per round
create or replace function crash_cashout(p_round uuid) returns json
language plpgsql security definer set search_path = public as $$
declare rd crash_rounds; m numeric; payout numeric; bal numeric;
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
  payout := least(payout, rd.bet + 5000000);   -- max win 5m per round
  update crash_rounds set status = 'cashed', cashout = m where id = rd.id;
  update profiles set balance = balance + payout where id = auth.uid() returning balance into bal;
  return json_build_object('won', true, 'multiplier', m, 'payout', payout, 'balance', bal, 'crash_point', rd.crash_point);
end $$;
revoke execute on function crash_cashout(uuid) from anon;

notify pgrst, 'reload schema';

-- ========== remove_roulette ==========
-- Jambling: roulette removed from the site. Make its RPCs refuse so the anon key can't call them. Run once.
create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Roulette has been removed'; end $$;

create or replace function roulette_recent() returns int[]
language plpgsql security definer set search_path = public as $$
begin return '{}'::int[]; end $$;

notify pgrst, 'reload schema';

-- ========== mines_bet1b ==========
-- Jambling: raise the Mines max bet to 1 billion. Run once in Supabase > SQL Editor.
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
  if p_bet > 1000000000 then raise exception 'Max bet is 1,000,000,000'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 15 then raise exception 'Pick 1 to 15 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

notify pgrst, 'reload schema';

-- ========== celestial_grant ==========
-- Jambling: let ONLY max grant the Celestial title to a player who has the Tester title
-- (skips the 200-rebirth requirement). Run once in Supabase > SQL Editor.

alter table profiles add column if not exists tester boolean not null default false;
alter table profiles add column if not exists celestial boolean not null default false;

create or replace function admin_grant_celestial(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; has_tester boolean;
begin
  if not am_owner() then raise exception 'Only max can grant Celestial'; end if;
  select id, username, tester into them, them_name, has_tester
    from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on and not coalesce(has_tester, false) then
    raise exception '% needs the Tester title before you can grant Celestial', them_name;
  end if;
  update profiles set celestial = p_on where id = them;
  return json_build_object('user', them_name, 'celestial', p_on);
end $$;
revoke execute on function admin_grant_celestial(text, boolean) from anon;
grant execute on function admin_grant_celestial(text, boolean) to authenticated;

notify pgrst, 'reload schema';

-- ========== archer ==========
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

-- ========== archer_rt (real-time; supersedes archer) ==========
-- Jambling: 1v1 "Archers" — REAL-TIME. Run once in Supabase > SQL Editor (replaces the turn-based archer.sql).
-- Movement, jumps, aiming and arrows sync player-to-player over Supabase Realtime (websocket broadcast, no DB per frame).
-- The database only owns HP, the 90-second clock and the payout:
--   * a player can only report damage to THEMSELVES (archer_damage), so nobody can fake hits on the other guy
--   * 90s match: most HP wins (tie = stakes back). Leave the game for 25s = forfeit.
--   Body 25 · Headshot 40 · 100 HP each.

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

-- ========== fix_pvp_cols ==========
-- Jambling: fix 'record "m" has no field "a_hp"'. Adds the 1v1 columns your database is missing. Run once.
alter table pvp_matches add column if not exists a_hp int not null default 100;
alter table pvp_matches add column if not exists b_hp int not null default 100;
alter table pvp_matches add column if not exists round int not null default 1;
alter table pvp_matches add column if not exists log jsonb not null default '[]';
alter table pvp_matches add column if not exists ax numeric;
alter table pvp_matches add column if not exists bx numeric;
alter table pvp_matches add column if not exists rt_start timestamptz;
alter table pvp_matches add column if not exists a_hit_at timestamptz;
alter table pvp_matches add column if not exists b_hit_at timestamptz;
notify pgrst, 'reload schema';

-- ========== archer_dmg2 ==========
-- Jambling: Archers damage now scales with pull strength (body 10-35, headshots 1.6x up to 56). Run once.
create or replace function archer_damage(p_id uuid, p_dmg int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; last_hit timestamptz; hp int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_dmg is null or p_dmg < 1 or p_dmg > 56 then raise exception 'Bad damage'; end if;   -- body 10-35, headshot up to 56
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

notify pgrst, 'reload schema';

-- ========== archer_arrows ==========
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

-- ========== pvp_fix ==========
-- Jambling: 1v1 fixes. Run once in Supabase > SQL Editor.
--  * "Finish your current match first" while no match is on screen: you could end up in two live matches at once
--    (accepting a challenge while one you sent also got accepted). Accepting now also checks the challenger is free.
--  * The 1v1 screen now always shows a live match first (it used to show the newest match, even if that one had ended).

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

create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  perform _settle_poison();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by (status = 'live') desc, created_at desc limit 1;   -- a live match always shows, even if a newer one already finished
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

-- clean up anyone currently stuck in more than one live match: keep the newest, settle the older ones as a draw (stakes back)
do $$
declare r record;
begin
  for r in select m.id from pvp_matches m
            where m.status = 'live'
              and exists (select 1 from pvp_matches n where n.status = 'live' and n.id <> m.id and n.created_at > m.created_at
                          and (n.a in (m.a, m.b) or n.b in (m.a, m.b))) loop
    perform _pvp_finish(r.id, null, 'tie');
  end loop;
end $$;

notify pgrst, 'reload schema';

-- ========== archer_upgrades ==========
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

-- ========== archer_equip ==========
-- Jambling: equip / unequip the 200 HP upgrade. Run once in Supabase > SQL Editor (after archer_upgrades.sql).
-- Owning it doesn't force it on any more: it only applies while equipped (on by default).
alter table archer_owned add column if not exists equipped boolean not null default true;

create or replace function _archer_maxhp(p_uid uuid) returns int language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from archer_owned where user_id = p_uid and kind = 'hp200' and equipped) then 200 else 100 end
$$;
revoke execute on function _archer_maxhp(uuid) from public, anon, authenticated;

create or replace function archer_arrows() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('owned', _archer_owned(auth.uid()), 'max_hp', _archer_maxhp(auth.uid()),
                           'equipped', coalesce((select json_agg(kind) from archer_owned where user_id = auth.uid() and equipped), '[]'::json),
                           'prices', json_build_object('poison', _archer_price('poison'), 'homing', _archer_price('homing'),
                                                       'sniper', _archer_price('sniper'), 'vampire', _archer_price('vampire'), 'hp200', _archer_price('hp200')))
$$;

create or replace function archer_equip(p_kind text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update archer_owned set equipped = coalesce(p_on, true) where user_id = auth.uid() and kind = p_kind;
  if not found then raise exception 'You don''t own that'; end if;
  return archer_arrows();
end $$;
revoke execute on function archer_equip(text, boolean) from anon;

notify pgrst, 'reload schema';
-- Jambling: GGEZ + Murphy's Law titles, and a title inventory (hide/show the titles you have). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists ggez boolean not null default false;        -- won 3 1v1s in a row
alter table profiles add column if not exists murphy boolean not null default false;      -- lost a 1b+ coin flip
alter table profiles add column if not exists pvp_streak int not null default 0;          -- current 1v1 win streak
alter table profiles add column if not exists hidden_titles text[] not null default '{}'; -- titles this player chose not to show

-- 1v1 results now track win streaks: 3 wins in a row (any 1v1 game, including Archers) unlocks GGEZ
create or replace function _pvp_finish(p_id uuid, w uuid, res text) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; s int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' then return; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
  if w is null then update profiles set pvp_streak = 0 where id in (m.a, m.b);
  else
    update profiles set pvp_streak = pvp_streak + 1 where id = w returning pvp_streak into s;
    update profiles set pvp_streak = 0 where id = case when w = m.a then m.b else m.a end;
    if s >= 3 then update profiles set ggez = true where id = w; end if;
  end if;
end $$;

-- coin flip: losing a bet of 1 billion or more unlocks Murphy's Law
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

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := p_pick;   -- good luck: always win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.90 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 90% win
  else res := case when random() < (case when _rigged(auth.uid()) then 0.44 else 0.5 end) then p_pick when p_pick = 'heads' then 'tails' else 'heads' end; end if;   -- rigged players: 44% win
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into coin_flips (user_id, bet, pick, result, won, delta) values (auth.uid(), p_bet, p_pick, res, won, delta);
  if not won and p_bet >= 1000000000 then update profiles set murphy = true where id = auth.uid(); end if;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta, 'murphy', (not won and p_bet >= 1000000000));
end $$;

-- title inventory: hide or show one of your titles
create or replace function set_title_hidden(p_title text, p_hidden boolean) returns text[]
language plpgsql security definer set search_path = public as $$
declare h text[];
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_hidden then update profiles set hidden_titles = array_append(array_remove(hidden_titles, p_title), p_title) where id = auth.uid() returning hidden_titles into h;
  else update profiles set hidden_titles = array_remove(hidden_titles, p_title) where id = auth.uid() returning hidden_titles into h; end if;
  return h;
end $$;
revoke execute on function set_title_hidden(text, boolean) from anon;
grant execute on function set_title_hidden(text, boolean) to authenticated;

notify pgrst, 'reload schema';
-- Jambling: "Jew" title (blue and white), granted by any admin. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists jew boolean not null default false;

create or replace function admin_grant_jew(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set jew = p_on where id = them;
  if _is_staff_not_owner() then perform _log_staff(them_name, case when p_on then 'granted the Jew title' else 'removed the Jew title' end); end if;
  return json_build_object('user', them_name, 'jew', p_on);
end $$;
revoke execute on function admin_grant_jew(text, boolean) from anon;
grant execute on function admin_grant_jew(text, boolean) to authenticated;

notify pgrst, 'reload schema';
-- Jambling: max can hand any title to a player who has the Tester title. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists granted_titles text[] not null default '{}';

create or replace function owner_grant_title(p_user text, p_title text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; has_tester boolean; g text[];
begin
  if not am_owner() then raise exception 'Only max can grant titles'; end if;
  if p_title not in ('Spoiled', 'Goated', 'Untouchable', 'Touchable', 'Reborn', 'Ascended', 'The Golden', 'Celestial', 'GGEZ', 'Murphy''s Law', 'King', 'Elite') then
    raise exception 'Unknown title %', p_title;
  end if;
  select id, username, tester into them, them_name, has_tester from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on and not coalesce(has_tester, false) then raise exception '% needs the Tester title first', them_name; end if;
  if p_on then update profiles set granted_titles = array_append(array_remove(granted_titles, p_title), p_title) where id = them returning granted_titles into g;
  else update profiles set granted_titles = array_remove(granted_titles, p_title) where id = them returning granted_titles into g; end if;
  perform _log_staff(them_name, case when p_on then 'granted the ' || p_title || ' title' else 'removed the granted ' || p_title || ' title' end);
  return json_build_object('user', them_name, 'title', p_title, 'on', p_on, 'granted', g);
end $$;
revoke execute on function owner_grant_title(text, text, boolean) from anon;
grant execute on function owner_grant_title(text, text, boolean) to authenticated;

notify pgrst, 'reload schema';
-- Jambling: Obby best times leaderboard. Run once in Supabase > SQL Editor.
create table if not exists obby_runs (
  user_id uuid primary key references profiles(id) on delete cascade,
  username text not null, secs numeric not null, deaths int not null default 0, coins int not null default 0,
  runs int not null default 1, updated_at timestamptz not null default now()
);
alter table obby_runs enable row level security;   -- no policies: only the functions touch it

create or replace function obby_finish(p_secs numeric, p_deaths int, p_coins int) returns json
language plpgsql security definer set search_path = public as $$
declare n text; best numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_secs is null or p_secs < 20 or p_secs > 36000 then raise exception 'Bad time'; end if;
  select username into n from profiles where id = auth.uid();
  insert into obby_runs (user_id, username, secs, deaths, coins) values (auth.uid(), n, p_secs, coalesce(p_deaths, 0), coalesce(p_coins, 0))
  on conflict (user_id) do update set runs = obby_runs.runs + 1, username = excluded.username, updated_at = now(),
    secs = least(obby_runs.secs, excluded.secs),
    deaths = case when excluded.secs < obby_runs.secs then excluded.deaths else obby_runs.deaths end,
    coins = greatest(obby_runs.coins, excluded.coins);
  select secs into best from obby_runs where user_id = auth.uid();
  return json_build_object('best', best, 'rank', (select count(*) + 1 from obby_runs where secs < best));
end $$;
revoke execute on function obby_finish(numeric, int, int) from anon;
grant execute on function obby_finish(numeric, int, int) to authenticated;

create or replace function obby_top() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('username', username, 'secs', secs, 'deaths', deaths, 'coins', coins, 'me', user_id = auth.uid())), '[]'::json)
  from (select * from obby_runs order by secs asc, updated_at asc limit 10) t
$$;
grant execute on function obby_top() to authenticated;

notify pgrst, 'reload schema';
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
-- Jambling: 1v1 Chameleon (Meccha Chameleon-style hide & seek in a 3D map). Run once in Supabase > SQL Editor (after archer_rt.sql / pvp_fix.sql / archer_upgrades.sql).
--   * Two rounds: each player hides once. 25s to hide, paint yourself and pose (the hunter is blind), then 60s for the hunter to find and shoot them.
--   * Whoever survives longer as the hider wins (both survive the full 60s or get tagged at the same second = draw).
--   * Score = seconds hidden (max 60) + 8 per taunt (a taunt pings your spot to the hunter). Higher total after both rounds wins.
--   * Hider gadgets (bought once, one use per round): Freeze, Smoke bomb, Decoy.
--   * Hide 25s + hunt 60s = 85s per round, 4s pause between rounds.

alter table pvp_matches add column if not exists hs_r1_end timestamptz;
alter table pvp_matches add column if not exists hs_r2_start timestamptz;
alter table pvp_matches add column if not exists hs_r2_end timestamptz;
alter table pvp_matches add column if not exists hs_t1 numeric;   -- seconds the challenger survived as hider
alter table pvp_matches add column if not exists hs_t2 numeric;   -- seconds the other player survived as hider
alter table pvp_matches add column if not exists hs_b1 int not null default 0;   -- taunt bonus points, challenger
alter table pvp_matches add column if not exists hs_b2 int not null default 0;   -- taunt bonus points, other player
alter table pvp_matches add column if not exists hs_taunt_at timestamptz;        -- last taunt (10s cooldown)

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
  -- score = seconds hidden (max 60) + 8 per taunt
  if m.hs_t1 + m.hs_b1 > m.hs_t2 + m.hs_b2 then perform _pvp_finish(m.id, m.a, 'win');
  elsif m.hs_t2 + m.hs_b2 > m.hs_t1 + m.hs_b1 then perform _pvp_finish(m.id, m.b, 'win');
  else perform _pvp_finish(m.id, null, 'tie'); end if;
end $$;
revoke execute on function _hs_finish(uuid) from public, anon, authenticated;

-- taunt: the hider pings their spot to the hunter and banks 8 points (10s cooldown, hunt phase only)
create or replace function hide_taunt(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; info json;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'hide' then raise exception 'No live match'; end if;
  info := _hs_info(m);
  if info->>'phase' <> 'seek' or (info->>'hider')::uuid <> me then raise exception 'Not now'; end if;
  if m.hs_taunt_at is not null and m.hs_taunt_at > now() - interval '10 seconds' then raise exception 'Taunt is cooling down'; end if;
  if me = m.a then update pvp_matches set hs_b1 = hs_b1 + 8, hs_taunt_at = now() where id = m.id;
  else update pvp_matches set hs_b2 = hs_b2 + 8, hs_taunt_at = now() where id = m.id; end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function hide_taunt(uuid) from anon;
grant execute on function hide_taunt(uuid) to authenticated;

-- the seeker shot the hider (either player's game may report it; the first report counts)
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
    update pvp_matches set status = 'live', rt_start = now(), hs_r1_end = null, hs_r2_start = null, hs_r2_end = null, hs_t1 = null, hs_t2 = null, hs_b1 = 0, hs_b2 = 0, hs_taunt_at = null,
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
      'my_bonus', case when is_a then m.hs_b1 else m.hs_b2 end, 'opp_bonus', case when is_a then m.hs_b2 else m.hs_b1 end,
      'my_score', case when is_a then m.hs_t1 + m.hs_b1 else m.hs_t2 + m.hs_b2 end, 'opp_score', case when is_a then m.hs_t2 + m.hs_b2 else m.hs_t1 + m.hs_b1 end,
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
-- Jambling: "OG" title, granted by max only. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists og boolean not null default false;

create or replace function owner_grant_og(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the OG title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set og = p_on where id = them;
  perform _log_staff(them_name, case when p_on then 'granted the OG title' else 'removed the OG title' end);
  return json_build_object('user', them_name, 'og', p_on);
end $$;
revoke execute on function owner_grant_og(text, boolean) from anon;
grant execute on function owner_grant_og(text, boolean) to authenticated;

notify pgrst, 'reload schema';
-- Jambling: "Creator" title, only ever on the site owner (max). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists creator boolean not null default false;

-- nobody can set it on themselves: it always mirrors whether the row is the site owner
create or replace function _creator_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.creator := exists (select 1 from site_owner where id = new.id);
  return new;
end $$;
drop trigger if exists creator_guard on profiles;
create trigger creator_guard before insert or update on profiles for each row execute function _creator_guard();

update profiles set creator = exists (select 1 from site_owner s where s.id = profiles.id);
notify pgrst, 'reload schema';
-- Jambling: max can hand any title (now including Creator) to a player who has the Tester title. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists granted_titles text[] not null default '{}';

create or replace function owner_grant_title(p_user text, p_title text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; has_tester boolean; g text[];
begin
  if not am_owner() then raise exception 'Only max can grant titles'; end if;
  if p_title not in ('Creator', 'Spoiled', 'Goated', 'Untouchable', 'Touchable', 'Reborn', 'Ascended', 'The Golden', 'Celestial', 'GGEZ', 'Murphy''s Law', 'King', 'Elite') then
    raise exception 'Unknown title %', p_title;
  end if;
  select id, username, tester into them, them_name, has_tester from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on and not coalesce(has_tester, false) then raise exception '% needs the Tester title first', them_name; end if;
  if p_on then update profiles set granted_titles = array_append(array_remove(granted_titles, p_title), p_title) where id = them returning granted_titles into g;
  else update profiles set granted_titles = array_remove(granted_titles, p_title) where id = them returning granted_titles into g; end if;
  perform _log_staff(them_name, case when p_on then 'granted the ' || p_title || ' title' else 'removed the granted ' || p_title || ' title' end);
  return json_build_object('user', them_name, 'title', p_title, 'on', p_on, 'granted', g);
end $$;
revoke execute on function owner_grant_title(text, text, boolean) from anon;
grant execute on function owner_grant_title(text, text, boolean) to authenticated;

notify pgrst, 'reload schema';
