-- Jambling: take the Quick title back from everyone and clear the Obby board for the new course. Run once in Supabase > SQL Editor.
update profiles set speedrun = false where speedrun;
update profiles set granted_titles = array_remove(granted_titles, 'Quick') where 'Quick' = any(granted_titles);
delete from obby_runs;
