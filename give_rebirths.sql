-- Jambling: give rebirths (owner only - just max). Run once in Supabase > SQL Editor.
create or replace function admin_give_rebirths(p_user text, p_n int) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; rb int;
begin
  if not am_owner() then raise exception 'Only max can give rebirths'; end if;
  if p_n is null or p_n <= 0 then raise exception 'Enter how many'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set rebirths = rebirths + p_n where id = them returning rebirths into rb;
  return json_build_object('user', them_name, 'rebirths', rb);
end $$;
revoke execute on function admin_give_rebirths(text, int) from anon;

notify pgrst, 'reload schema';
