-- List all admins and all mods. Run in Supabase > SQL Editor.
select p.username, 'admin' as role from admins a join profiles p on p.id = a.user_id
union all
select p.username, 'mod' from moderators m join profiles p on p.id = m.user_id
order by role, username;
