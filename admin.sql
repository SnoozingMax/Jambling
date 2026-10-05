-- Jambling: admin panel (boosts). Run once in Supabase > SQL Editor (safe to run again).
-- Run ride.sql first (it adds the boost columns).

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
