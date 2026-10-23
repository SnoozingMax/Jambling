-- Jambling: let ONLY max add/remove admins. Run once in Supabase > SQL Editor.
-- Other admins can't use this (gated on am_owner, not is_admin). The owner (max) can never be removed (existing trigger).

create or replace function owner_set_admin(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can change admins'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if exists (select 1 from site_owner where id = them) then raise exception 'max is always an admin'; end if;
  if p_on then insert into admins values (them) on conflict do nothing;
  else delete from admins where user_id = them; end if;
  return json_build_object('user', them_name, 'admin', p_on);
end $$;
revoke execute on function owner_set_admin(text, boolean) from public, anon;
grant execute on function owner_set_admin(text, boolean) to authenticated;

notify pgrst, 'reload schema';
