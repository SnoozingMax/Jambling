-- Jambling: only max can ban/unban and make/remove mods. Other admins can't.
-- Run once in Supabase > SQL Editor (safe to run again).

create or replace function am_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from site_owner where id = auth.uid())
$$;

-- banning / unbanning: owner only (SQL you run yourself and the bot auto-ban still work)
create or replace function _owner_only_ban() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.banned is distinct from old.banned and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can ban or unban';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_ban on profiles;
create trigger owner_only_ban before update on profiles
for each row execute function _owner_only_ban();

-- making / removing mods: owner only
create or replace function _owner_only_mods() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not am_owner() then
    raise exception 'Only max can make or remove mods';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists owner_only_mods on moderators;
create trigger owner_only_mods before insert or delete on moderators
for each row execute function _owner_only_mods();

notify pgrst, 'reload schema';
