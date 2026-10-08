-- Jambling: admin boost lasts 3 minutes (was 5). Run once in Supabase > SQL Editor.

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
     set boost_until = least(greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '3 minutes',
                             clock_timestamp() + interval '30 minutes')
   where id = them returning boost_until into until;
  return json_build_object('user', them_name, 'until', until);
end $$;

notify pgrst, 'reload schema';
