-- Demote Bebewill from admin to mod. Run once in Supabase > SQL Editor.
-- (Works with or without single_role.sql: it removes admin and adds mod explicitly.)
do $$
declare uid uuid;
begin
  select id into uid from profiles where lower(username) = 'bebewill' order by created_at limit 1;
  if uid is null then raise exception 'No player named Bebewill'; end if;
  delete from admins where user_id = uid;
  insert into moderators (user_id) values (uid) on conflict do nothing;
end $$;

-- confirm (should show bebewill as mod only):
select p.username, 'admin' as role from admins a join profiles p on p.id = a.user_id where lower(p.username) = 'bebewill'
union all
select p.username, 'mod' from moderators m join profiles p on p.id = m.user_id where lower(p.username) = 'bebewill';
