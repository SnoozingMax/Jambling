-- Jambling: remove the Honored One title (from the grant list and from everyone who has it). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists granted_titles text[] not null default '{}';

create or replace function owner_grant_title(p_user text, p_title text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; has_tester boolean; g text[];
begin
  if not am_owner() then raise exception 'Only max can grant titles'; end if;
  if p_title not in ('Creator', 'OG', 'Aurora', 'Tester', 'Jew', 'Quick', 'Spoiled', 'Goated', 'Untouchable', 'Touchable',
                     'Reborn', 'Ascended', 'The Golden', 'Celestial', 'GGEZ', 'Murphy''s Law', 'King', 'Elite') then
    raise exception 'Unknown title %', p_title;
  end if;
  select id, username, tester into them, them_name, has_tester from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on and p_title = 'Creator' and not coalesce(has_tester, false) then raise exception '% needs the Tester title first', them_name; end if;
  -- titles that have their own switch on the profile (so their perks still work)
  if p_title = 'Tester' then update profiles set tester = p_on where id = them;
  elsif p_title = 'Aurora' then update profiles set gifted = p_on where id = them;
  elsif p_title = 'OG' then update profiles set og = p_on where id = them;
  elsif p_title = 'Jew' then update profiles set jew = p_on where id = them;
  elsif p_title = 'Quick' then update profiles set speedrun = p_on where id = them;
  elsif p_on then update profiles set granted_titles = array_append(array_remove(granted_titles, p_title), p_title) where id = them;
  else update profiles set granted_titles = array_remove(granted_titles, p_title) where id = them; end if;
  select granted_titles into g from profiles where id = them;
  perform _log_staff(them_name, case when p_on then 'granted the ' || p_title || ' title' else 'removed the ' || p_title || ' title' end);
  return json_build_object('user', them_name, 'title', p_title, 'on', p_on, 'granted', g);
end $$;
revoke execute on function owner_grant_title(text, text, boolean) from anon;
grant execute on function owner_grant_title(text, text, boolean) to authenticated;

notify pgrst, 'reload schema';

update profiles set granted_titles = array_remove(granted_titles, 'Honored One') where 'Honored One' = any(granted_titles);
notify pgrst, 'reload schema';
