-- Jambling: let admins grant the Celestial title to a player who has the Tester title
-- (skips the 200-rebirth requirement). Run once in Supabase > SQL Editor.

alter table profiles add column if not exists tester boolean not null default false;
alter table profiles add column if not exists celestial boolean not null default false;

create or replace function admin_grant_celestial(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; has_tester boolean;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username, tester into them, them_name, has_tester
    from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on and not coalesce(has_tester, false) then
    raise exception '% needs the Tester title before you can grant Celestial', them_name;
  end if;
  update profiles set celestial = p_on where id = them;
  return json_build_object('user', them_name, 'celestial', p_on);
end $$;
revoke execute on function admin_grant_celestial(text, boolean) from anon;
grant execute on function admin_grant_celestial(text, boolean) to authenticated;

notify pgrst, 'reload schema';
