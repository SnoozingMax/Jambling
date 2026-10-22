-- Jambling: "Gifted" rainbow title, grantable ONLY by max (owner). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists gifted boolean not null default false;

create or replace function admin_gift_title(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the Gifted title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set gifted = p_on where id = them;
  return json_build_object('user', them_name, 'gifted', p_on);
end $$;
revoke execute on function admin_gift_title(text, boolean) from anon;

notify pgrst, 'reload schema';
