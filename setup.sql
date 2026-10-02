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
  elsif rd.status = 'cashed' then
    return json_build_object('crashed', false);
  end if;

  m := exp(0.09 * extract(epoch from clock_timestamp() - rd.started_at));
  if m >= rd.crash_point then
    update crash_rounds set status = 'crashed' where id = rd.id;
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

  return json_build_object('won', true, 'multiplier', m, 'payout', payout, 'balance', bal);
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

alter table profiles add column if not exists last_daily timestamptz;

create or replace function claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare
  last timestamptz;
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select last_daily into last from profiles where id = auth.uid() for update;
  if last is not null and now() < last + interval '24 hours' then
    raise exception 'Daily reward not ready yet';
  end if;
  update profiles set balance = balance + 250, last_daily = now()
   where id = auth.uid() returning balance into bal;
  return json_build_object('balance', bal, 'next', now() + interval '24 hours');
end $$;
