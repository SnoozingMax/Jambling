-- Jambling: Ride game. Hold to ride the chart: up = you gain, down = you lose.
-- Run once in Supabase > SQL Editor (safe to run again).
-- 150 steps x 200ms = 30s rounds. Prices are generated here and only revealed as time passes.

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
