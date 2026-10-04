-- Jambling: Ride game (smooth version). Run once in Supabase > SQL Editor (safe to run again).
-- 150 steps x 200ms = 30s. Prices are generated here and revealed slightly ahead of time.
-- The browser animates locally and reports the step where you pressed/released;
-- the server only accepts steps close to the real current step.

create table if not exists chart_rounds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null,
  prices float8[] not null,
  started_at timestamptz not null default clock_timestamp(),
  status text not null default 'live',
  holding boolean not null default false,
  hold_step int not null default 0,
  mult float8 not null default 1,
  payout numeric
);
alter table chart_rounds enable row level security;

-- remove the old versions
drop function if exists chart_poll(uuid, int);
drop function if exists chart_hold(uuid, boolean);
drop function if exists chart_cashout(uuid);
drop function if exists _chart_finish(uuid);
drop function if exists _chart_settle(uuid);

-- current real step
create or replace function _chart_k(rd chart_rounds) returns int
language sql stable as $$
  select least(150, floor(extract(epoch from clock_timestamp() - rd.started_at) / 0.2)::int)
$$;

-- settle up to step p_step (clamped to a fair window). internal.
create or replace function _chart_settle(p_id uuid, p_step int) returns chart_rounds
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
  k int;
  a int;
begin
  select * into rd from chart_rounds where id = p_id for update;
  if rd.status <> 'live' then return rd; end if;
  k := _chart_k(rd);
  a := coalesce(p_step, k);
  a := greatest(a, k - 6, rd.hold_step);   -- no more than ~1.2s in the past
  a := least(a, k + 3, 150);               -- no more than ~0.6s ahead
  a := greatest(a, rd.hold_step);
  if rd.holding and a > rd.hold_step then
    rd.mult := least(20, rd.mult * rd.prices[a + 1] / rd.prices[rd.hold_step + 1]);
  end if;
  rd.hold_step := a;
  update chart_rounds set mult = rd.mult, hold_step = a where id = rd.id;
  return rd;
end $$;

create or replace function _chart_finish(p_id uuid, p_step int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
  pay numeric;
  bal numeric;
begin
  rd := _chart_settle(p_id, p_step);
  if rd.status <> 'live' then
    select balance into bal from profiles where id = rd.user_id;
    return json_build_object('status', 'done', 'payout', rd.payout, 'mult', rd.mult, 'balance', bal);
  end if;
  pay := round((rd.bet * rd.mult)::numeric, 2);
  update chart_rounds set status = 'done', payout = pay, holding = false where id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('status', 'done', 'payout', pay, 'mult', rd.mult, 'balance', bal);
end $$;

revoke execute on function _chart_settle(uuid, int) from public, anon, authenticated;
revoke execute on function _chart_finish(uuid, int) from public, anon, authenticated;

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

  for old in select id from chart_rounds where user_id = auth.uid() and status = 'live' loop
    perform _chart_finish(old, 150);
  end loop;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  for i in 1..150 loop
    v := 0.9 * v + (random() - 0.5) * 0.02;
    p := p * exp(v - 0.0004);
    arr := arr || p;
  end loop;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into chart_rounds (user_id, bet, prices) values (auth.uid(), p_bet, arr) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal, 'prices', arr[1:4]);
end $$;

-- prices from index p_from (0-based) up to ~0.6s ahead of now
create or replace function chart_poll(p_round uuid, p_from int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
  k int;
begin
  select * into rd from chart_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := _chart_k(rd);
  return json_build_object('prices', rd.prices[p_from + 1 : least(151, k + 4)], 'k', k, 'status', rd.status);
end $$;

create or replace function chart_hold(p_round uuid, p_on boolean, p_step int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd chart_rounds;
begin
  perform 1 from chart_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  rd := _chart_settle(p_round, p_step);
  if rd.status <> 'live' then return json_build_object('status', rd.status, 'mult', rd.mult); end if;
  if rd.hold_step >= 150 then return _chart_finish(p_round, 150); end if;
  update chart_rounds set holding = p_on where id = p_round;
  return json_build_object('status', 'live', 'mult', rd.mult, 'step', rd.hold_step);
end $$;

create or replace function chart_cashout(p_round uuid, p_step int) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform 1 from chart_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  return _chart_finish(p_round, p_step);
end $$;
