-- Jambling: make Yoink an admin, but nobody except max can do anything to max's account.
-- Run once in Supabase > SQL Editor (safe to run again).

-- the owner (max) is remembered by account id, so renaming can't fake it
create table if not exists site_owner (id uuid primary key);
alter table site_owner enable row level security;   -- no policies: only functions read it
insert into site_owner select id from profiles where username = 'max' on conflict do nothing;

-- other admins/mods can't touch the owner: no taking coins, banning, renaming, rebirths, boosts, bad luck,
-- waiting room. Coins going UP (gifts, 1v1 wins) are still fine. SQL you run yourself is never blocked.
create or replace function _protect_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or auth.uid() = new.id or not exists (select 1 from site_owner where id = new.id) then
    return new;
  end if;
  if new.balance < old.balance
     or new.banned is distinct from old.banned
     or new.username is distinct from old.username
     or new.rebirths is distinct from old.rebirths
     or new.boost_until is distinct from old.boost_until
     or new.badluck_until is distinct from old.badluck_until
     or new.approved is distinct from old.approved then
    raise exception 'Only max can change max''s account';
  end if;
  return new;
end $$;
drop trigger if exists protect_owner on profiles;
create trigger protect_owner before update on profiles
for each row execute function _protect_owner();

-- also can't delete or demote the owner
create or replace function _protect_owner_rows() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() <> old.user_id and exists (select 1 from site_owner where id = old.user_id) then
    raise exception 'Only max can change max''s account';
  end if;
  return old;
end $$;
drop trigger if exists protect_owner_admin on admins;
create trigger protect_owner_admin before delete on admins
for each row execute function _protect_owner_rows();

create or replace function _protect_owner_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() <> old.id and exists (select 1 from site_owner where id = old.id) then
    raise exception 'Only max can change max''s account';
  end if;
  return old;
end $$;
drop trigger if exists protect_owner_delete on profiles;
create trigger protect_owner_delete before delete on profiles
for each row execute function _protect_owner_delete();

-- Yoink: admin (and no longer listed as a mod)
insert into admins select id from profiles where lower(username) = 'yoink' on conflict do nothing;
delete from moderators where user_id = (select id from profiles where lower(username) = 'yoink');
update profiles set approved = true where lower(username) = 'yoink';

select p.username as admins from admins a join profiles p on p.id = a.user_id;
