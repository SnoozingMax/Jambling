-- Jambling: seasons + legacy, admin rename / take rebirths, delete brezscalesisthegoat.
-- Run once in Supabase > SQL Editor (safe to run again). Run admin.sql and ban.sql first.

-- ---------- delete the account ----------
delete from auth.users where id in (select id from profiles where lower(username) = 'brezscalesisthegoat');

-- ---------- seasons ----------
create table if not exists seasons (id serial primary key, ended_at timestamptz not null default now());
create table if not exists season_results (
  season_id int not null references seasons(id) on delete cascade,
  user_id uuid, username text not null, balance numeric not null, rebirths int not null, rank int not null
);
alter table seasons enable row level security;
alter table season_results enable row level security;
drop policy if exists "seasons readable" on seasons;
create policy "seasons readable" on seasons for select to authenticated using (true);
drop policy if exists "season results readable" on season_results;
create policy "season results readable" on season_results for select to authenticated using (true);

-- end the season: save everyone's final standing, then reset everyone
create or replace function admin_new_season() returns json
language plpgsql security definer set search_path = public as $$
declare sid int; n int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  insert into seasons default values returning id into sid;
  insert into season_results (season_id, user_id, username, balance, rebirths, rank)
    select sid, id, username, balance, rebirths, row_number() over (order by rebirths desc, balance desc)
      from profiles where not banned;
  get diagnostics n = row_count;
  -- end anything in progress
  update crash_rounds set status = 'crashed' where status = 'live';
  update ride_rounds set status = 'abandoned', payout = 0 where status = 'live';
  update bj_hands set status = 'done', result = 'void', payout = 0 where status = 'live';
  update profiles set balance = 1000, rebirths = 0, boost_until = null where true;
  return json_build_object('season', sid, 'players', n);
end $$;

-- ---------- admin: rename (login name changes too) ----------
create or replace function admin_rename(p_user text, p_new text) returns json
language plpgsql security definer set search_path = public, auth as $$
declare them uuid; old_name text; new_email text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  p_new := trim(p_new);
  if p_new !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'New name: 3-20 letters, numbers, or _'; end if;
  select id, username into them, old_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if exists (select 1 from profiles where lower(username) = lower(p_new) and id <> them) then raise exception 'That name is taken'; end if;
  new_email := lower(p_new) || '@users.jambling.app';
  update profiles set username = p_new where id = them;
  -- accounts made with username + passcode log in with this hidden email
  if (select email from auth.users where id = them) like '%@users.jambling.app' then
    if exists (select 1 from auth.users where email = new_email and id <> them) then raise exception 'That name is taken'; end if;
    update auth.users set email = new_email where id = them;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', new_email)
      where user_id = them and provider = 'email';
  end if;
  return json_build_object('old', old_name, 'new', p_new);
end $$;

-- ---------- admin: take rebirths ----------
create or replace function admin_take_rebirths(p_user text, p_n int) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; rb int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_n is null or p_n <= 0 then raise exception 'Enter how many'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set rebirths = greatest(0, rebirths - p_n) where id = them returning rebirths into rb;
  return json_build_object('user', them_name, 'rebirths', rb);
end $$;

notify pgrst, 'reload schema';
