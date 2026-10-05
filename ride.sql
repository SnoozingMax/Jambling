-- Jambling: Ride (v3). Infinite chart until you press Stop.
-- Run once in Supabase > SQL Editor (safe to run again).
-- The chart is generated from a seed (same math in the browser and here), so it runs
-- smoothly with no network lag. Holds are reported live; Stop replays the chart to pay out.

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
  ev_left int := 0; ev_dir float8 := 0; d int := 0; base float8 := 100;
  size float8 := 0; rr int := 1; w float8 := 1; wk int;
  k int; ev int; mid boolean;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    mid := false;
    if ev_left = 0 and u3 > 0.99 then
      if u2 < 0.45 then                                   -- pump: +65% to +170% over 2.5-6s
        ev_dir := 1;
        d := 25 + floor(u1 * 36)::int;
        size := 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53));
        rr := ceil(d::float8 / 4)::int;
        w := (rr * (rr + 1))::float8 / 2 + (d - rr) * rr;
        ev_left := d; base := p;
      else                                                -- dump: random size and length
        ev_dir := -1;
        d := 3 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := 0.25 + 0.45 * (u1 * 53 - floor(u1 * 53));
        w := (d * (d + 1))::float8 / 2;
        ev_left := d;
      end if;
    elsif ev_left > 0 and ev_dir > 0 and u3 < 0.012 then  -- surprise dump mid-pump: wipes the pump out
      ev_dir := -1;
      d := 3;
      size := greatest(0, ln(p / base)) + 0.9 + 0.3 * (u1 * 53 - floor(u1 * 53));
      w := (d * (d + 1))::float8 / 2;
      ev_left := d;
    end if;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then wk := least(k, rr); else wk := d - k + 1; end if;   -- pumps build up, dumps hit hardest first
      p := p * exp(ev_dir * size * wk / w + (u2 - 0.5) * 0.012);
      ev_left := ev_left - 1; v := 0;
    else
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol);
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
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  m := least(m, 25);

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = auth.uid()), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  update profiles set balance = balance + pay where id = auth.uid() returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a);
end $$;

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
