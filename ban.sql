-- Jambling: bans. Run once in Supabase > SQL Editor (safe to run again). Run admin.sql first.

alter table profiles add column if not exists banned boolean not null default false;

-- a banned player's coins are frozen at 0, whatever any game or gift tries to do
create or replace function _keep_banned_broke() returns trigger
language plpgsql as $$
begin
  if new.banned then new.balance := 0; end if;
  return new;
end $$;
drop trigger if exists keep_banned_broke on profiles;
create trigger keep_banned_broke before update on profiles
for each row execute function _keep_banned_broke();

create or replace function admin_ban(p_user text, p_ban boolean) returns json
language plpgsql security definer set search_path = public, auth as $$
declare
  them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_ban and exists (select 1 from admins where user_id = them) then raise exception 'Can''t ban an admin'; end if;

  update profiles set banned = p_ban where id = them;
  -- block sign-in, and sign them out everywhere
  update auth.users set banned_until = case when p_ban then 'infinity'::timestamptz else null end where id = them;
  if p_ban then delete from auth.sessions where user_id = them; end if;
  return json_build_object('user', them_name, 'banned', p_ban);
end $$;

-- ban YahuBot right now
update profiles set banned = true where lower(username) = 'yahubot';
update auth.users set banned_until = 'infinity' where id in (select id from profiles where lower(username) = 'yahubot');
delete from auth.sessions where user_id in (select id from profiles where lower(username) = 'yahubot');
select username, banned, balance from profiles where lower(username) = 'yahubot';

notify pgrst, 'reload schema';
