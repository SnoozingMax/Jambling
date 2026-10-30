-- Jambling: wipe the Obby fastest-runs board for the new 18-stage course. Run once in Supabase > SQL Editor.
-- Coins, titles and everything else stay. (Quick titles already earned are kept; remove the comment on the last line to take them back too.)
delete from obby_runs;
-- update profiles set speedrun = false;
