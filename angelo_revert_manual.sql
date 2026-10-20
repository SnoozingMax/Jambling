-- Jambling: MANUAL revert of angelo's admin session (run this if the auto pg_cron job didn't fire).
update profiles p set balance = s.balance, rebirths = s.rebirths, username = s.username,
       banned = s.banned, approved = s.approved, board_hidden = s.board_hidden
  from _angelo_snap s where p.id = s.id;
insert into profiles select * from _angelo_snap s where not exists (select 1 from profiles p where p.id = s.id);
delete from admins;     insert into admins select * from _angelo_admins;
delete from moderators; insert into moderators select * from _angelo_mods;
select cron.unschedule('angelo_revert');   -- ignore error if pg_cron unused
drop table if exists _angelo_snap; drop table if exists _angelo_admins;
drop table if exists _angelo_mods; drop table if exists _angelo_deadline;
