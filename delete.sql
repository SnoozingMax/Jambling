-- Jambling: admin "Delete account". Run once in Supabase > SQL Editor (safe to run again).
create or replace function admin_delete(p_user text) returns json
language plpgsql security definer set search_path = public, auth as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if exists (select 1 from admins where user_id = them) then raise exception 'Can''t delete an admin'; end if;
  delete from auth.users where id = them;   -- removes their profile and games too
  return json_build_object('user', them_name);
end $$;
notify pgrst, 'reload schema';
