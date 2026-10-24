-- Make laoo an admin. Run once in Supabase > SQL Editor.
insert into admins select id from profiles where lower(username) = 'laoo' on conflict do nothing;
-- check it worked (should list laoo):
select username from profiles p join admins a on a.user_id = p.id order by username;
