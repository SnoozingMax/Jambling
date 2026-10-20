-- Jambling: make angelo admin now; auto-revert everything he does in 10 minutes. Run once in Supabase > SQL Editor.
-- Requires pg_cron (Supabase: Database > Extensions > enable "pg_cron" if this errors).
create extension if not exists pg_cron;

-- 1) snapshot the whole players table + who is admin/mod right now
drop table if exists _angelo_snap;
create table _angelo_snap as select * from profiles;
drop table if exists _angelo_admins;  create table _angelo_admins as select * from admins;
drop table if exists _angelo_mods;     create table _angelo_mods   as select * from moderators;
drop table if exists _angelo_deadline; create table _angelo_deadline(at timestamptz);
insert into _angelo_deadline values (now() + interval '10 minutes');

-- 2) make angelo an admin
insert into admins(user_id) select id from profiles where lower(username) = 'angelo' on conflict do nothing;

-- 3) the revert: restore the snapshot, strip angelo's admin, clean up, unschedule itself
create or replace function _angelo_revert() returns void
language plpgsql security definer set search_path = public as $$
begin
  if now() < (select at from _angelo_deadline) then return; end if;   -- not yet 10 min
  -- restore every player's coins / rebirths / name / ban / approval / board flag
  update profiles p set balance = s.balance, rebirths = s.rebirths, username = s.username,
         banned = s.banned, approved = s.approved, board_hidden = s.board_hidden
    from _angelo_snap s where p.id = s.id;
  -- re-create any player angelo deleted
  insert into profiles select * from _angelo_snap s where not exists (select 1 from profiles p where p.id = s.id);
  -- restore admin / mod lists exactly as they were (removes angelo, restores anyone he touched)
  delete from admins;      insert into admins select * from _angelo_admins;
  delete from moderators;  insert into moderators select * from _angelo_mods;
  -- clean up and stop the job
  perform cron.unschedule('angelo_revert');
  drop table if exists _angelo_snap; drop table if exists _angelo_admins;
  drop table if exists _angelo_mods; drop table if exists _angelo_deadline;
end $$;

-- 4) run the check every minute; it fires the revert once 10 min have passed
select cron.schedule('angelo_revert', '* * * * *', $$select _angelo_revert()$$);
