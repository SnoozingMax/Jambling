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
