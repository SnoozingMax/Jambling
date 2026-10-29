-- Jambling: "OG" title, granted by max only. Run once in Supabase > SQL Editor.
alter table profiles add column if not exists og boolean not null default false;

create or replace function owner_grant_og(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the OG title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set og = p_on where id = them;
  perform _log_staff(them_name, case when p_on then 'granted the OG title' else 'removed the OG title' end);
  return json_build_object('user', them_name, 'og', p_on);
end $$;
revoke execute on function owner_grant_og(text, boolean) from anon;
grant execute on function owner_grant_og(text, boolean) to authenticated;

notify pgrst, 'reload schema';
