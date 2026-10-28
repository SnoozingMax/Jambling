-- Jambling: "Jew" title (blue and white), granted by any admin. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists jew boolean not null default false;

create or replace function admin_grant_jew(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set jew = p_on where id = them;
  if _is_staff_not_owner() then perform _log_staff(them_name, case when p_on then 'granted the Jew title' else 'removed the Jew title' end); end if;
  return json_build_object('user', them_name, 'jew', p_on);
end $$;
revoke execute on function admin_grant_jew(text, boolean) from anon;
grant execute on function admin_grant_jew(text, boolean) to authenticated;

notify pgrst, 'reload schema';
