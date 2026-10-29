-- Jambling: "Creator" title, only ever on the site owner (max). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists creator boolean not null default false;

-- nobody can set it on themselves: it always mirrors whether the row is the site owner
create or replace function _creator_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.creator := exists (select 1 from site_owner where id = new.id);
  return new;
end $$;
drop trigger if exists creator_guard on profiles;
create trigger creator_guard before insert or update on profiles for each row execute function _creator_guard();

update profiles set creator = exists (select 1 from site_owner s where s.id = profiles.id);
notify pgrst, 'reload schema';
