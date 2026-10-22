-- Jambling: Shop (rush hour, boost, steal). Run once in Supabase > SQL Editor.

-- let shop purchases pass the owner-only rush/boost guards via a transaction-local flag
create or replace function _owner_only_rush() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.rush_until is distinct from old.rush_until and auth.uid() is not null and not am_owner()
     and coalesce(current_setting('jambling.shop', true), '') <> '1' then
    raise exception 'Only max can start or end rush hour';
  end if;
  return new;
end $$;

create or replace function _owner_only_boost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.boost_until is not null and new.boost_until is distinct from old.boost_until
     and auth.uid() is not null and not am_owner()
     and coalesce(current_setting('jambling.shop', true), '') <> '1' then
    raise exception 'Only max can boost';
  end if;
  return new;
end $$;

-- Rush Hour: 1 quadrillion -> global rush hour for everyone, 30 seconds
create or replace function shop_rush() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e15; bal numeric; until timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 1 quadrillion coins for Rush Hour'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform set_config('jambling.shop', '1', true);
  update site_state set rush_until = greatest(coalesce(rush_until, clock_timestamp()), clock_timestamp()) + interval '30 seconds'
    where id = 1 returning rush_until into until;
  return json_build_object('ok', true, 'balance', bal, 'until', until);
end $$;

-- Boost (good luck): 1 decillon -> buyer gets good luck for 10 seconds
create or replace function shop_boost() returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e33; bal numeric; until timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < cost then raise exception 'You need 1 decillion coins for Good Luck'; end if;
  update profiles set balance = balance - cost where id = auth.uid() returning balance into bal;
  perform set_config('jambling.shop', '1', true);
  update profiles set boost_until = greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '10 seconds'
    where id = auth.uid() returning boost_until into until;
  return json_build_object('ok', true, 'balance', bal, 'until', until);
end $$;

-- Steal: 10 billion fee -> take 5% of a chosen player's coins
create or replace function shop_steal(p_target text) returns json
language plpgsql security definer set search_path = public as $$
declare cost numeric := 1e10; me uuid := auth.uid(); them uuid; them_name text; bal numeric; tbal numeric; stolen numeric;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_target)) and approved and not banned order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_target; end if;
  if them = me then raise exception 'You can''t steal from yourself'; end if;
  if exists (select 1 from site_owner where id = them) then raise exception 'You can''t steal from the owner'; end if;
  select balance into bal from profiles where id = me for update;
  if bal < cost then raise exception 'You need 10 billion coins to steal'; end if;
  select balance into tbal from profiles where id = them for update;
  stolen := round(tbal * 0.05, 2);
  update profiles set balance = balance - stolen where id = them;
  update profiles set balance = balance - cost + stolen where id = me returning balance into bal;
  return json_build_object('ok', true, 'balance', bal, 'target', them_name, 'stolen', stolen);
end $$;
revoke execute on function shop_rush() from anon;
revoke execute on function shop_boost() from anon;
revoke execute on function shop_steal(text) from anon;

notify pgrst, 'reload schema';
