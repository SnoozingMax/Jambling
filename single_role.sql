-- Jambling: a player can't be admin and mod at the same time. Run once in Supabase > SQL Editor.
-- Making someone an admin drops their mod role; making someone a mod drops their admin role. The owner stays admin.

create or replace function _one_role_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'admins' then
    delete from moderators where user_id = new.user_id;       -- admin supersedes mod
  else
    if exists (select 1 from site_owner where id = new.user_id) then
      raise exception 'The owner is always an admin, not a mod';
    end if;
    delete from admins where user_id = new.user_id;           -- mod drops admin
  end if;
  return new;
end $$;

drop trigger if exists one_role_admins on admins;
create trigger one_role_admins before insert on admins for each row execute function _one_role_only();
drop trigger if exists one_role_mods on moderators;
create trigger one_role_mods before insert on moderators for each row execute function _one_role_only();

-- clean up anyone who is currently both (admin wins)
delete from moderators where user_id in (select user_id from admins);

notify pgrst, 'reload schema';
