-- Jambling: moderators + Bad luck. Run once in Supabase > SQL Editor (safe to run again).
-- Run ride.sql and blackjack.sql first (they handle Bad luck in Ride and Blackjack).

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
