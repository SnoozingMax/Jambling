-- Jambling: set _TMBTS's passcode to 1131. Run once in Supabase > SQL Editor.
-- (Accounts sign in as <username>@users.jambling.app with password 'jmb-' + passcode.)
update auth.users
   set encrypted_password = crypt('jmb-1131', gen_salt('bf'))
 where email = '_tmbts@users.jambling.app';
select count(*) as accounts_updated from auth.users where email = '_tmbts@users.jambling.app';
