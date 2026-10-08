-- Jambling: admins can gift coins. Run once in Supabase > SQL Editor (safe to run again).
create or replace function admin_give(p_user text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; bal numeric;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 then raise exception 'Enter an amount'; end if;
  if p_amount > 1e12 then raise exception 'Max gift is 1,000,000,000,000'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1 for update;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set balance = balance + p_amount where id = them returning balance into bal;
  return json_build_object('user', them_name, 'gave', p_amount, 'balance', bal);
end $$;
revoke execute on function admin_give(text, numeric) from anon;

notify pgrst, 'reload schema';
