-- Jambling: set _tmbts's passcode to 1131 (looked up by profile username, any casing). Run once in Supabase > SQL Editor.
update auth.users u
   set encrypted_password = crypt('jmb-1131', gen_salt('bf'))
  from profiles p
 where p.id = u.id and lower(p.username) like '%tmbts%';
-- who matched (should be exactly one row)
select p.username, u.email from profiles p join auth.users u on u.id = p.id where lower(p.username) like '%tmbts%';
