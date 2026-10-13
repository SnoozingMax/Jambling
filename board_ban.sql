-- Jambling: leaderboard ban. Hides a player from the leaderboard; they can still play.
-- Run once in Supabase > SQL Editor (safe to run again).

alter table profiles add column if not exists board_hidden boolean not null default false;

create or replace function admin_board_ban(p_user text, p_hide boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_hide and exists (select 1 from site_owner where id = them) and not am_owner() then raise exception 'Only max can change max''s account'; end if;
  update profiles set board_hidden = p_hide where id = them;
  if not am_owner() then
    perform _log_staff(them_name, case when p_hide then 'leaderboard banned' else 'un-leaderboard banned' end);
  end if;
  return json_build_object('user', them_name, 'hidden', p_hide);
end $$;
revoke execute on function admin_board_ban(text, boolean) from anon;

notify pgrst, 'reload schema';
