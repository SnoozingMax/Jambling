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
