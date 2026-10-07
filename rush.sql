-- Jambling: Rush hour. Run once in Supabase > SQL Editor (safe to run again).
-- Run ride.sql, blackjack.sql and badluck.sql first.

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
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.75 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 75% win
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

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then cp := 1.01;
  elsif _rush_now() then                                     -- rush hour: 1.5x minimum, ~5x typical
    r := random();
    cp := least(1000, greatest(1.5, floor(2.5 / (1 - r) * 100) / 100))::numeric;
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric;
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;

  return json_build_object('round_id', rid, 'balance', bal);
end $$;

notify pgrst, 'reload schema';
