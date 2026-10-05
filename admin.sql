-- Jambling: admin panel (boosts). Run once in Supabase > SQL Editor (safe to run again).
-- Run ride.sql first (it adds the boost columns).

create table if not exists admins (user_id uuid primary key references profiles(id) on delete cascade);
alter table admins enable row level security;   -- no policies: only functions read it
insert into admins select id from profiles where username = 'max' on conflict do nothing;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

-- give a player 5 minutes of nonstop pump in Ride, for a price in coins
create or replace function admin_boost(p_user text, p_cost numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; bal numeric; until timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_cost := round(coalesce(p_cost, 0), 2);
  if p_cost < 0 then raise exception 'Invalid price'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;

  select balance into bal from profiles where id = them for update;
  if bal < p_cost then raise exception '% only has % coins', them_name, bal; end if;
  update profiles
     set balance = balance - p_cost,
         boost_until = greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '5 minutes'
   where id = them returning balance, boost_until into bal, until;
  return json_build_object('user', them_name, 'balance', bal, 'until', until);
end $$;

notify pgrst, 'reload schema';
