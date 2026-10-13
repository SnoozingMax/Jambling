-- Jambling: rebirth cost 100k, then 150k, 200k, 250k... (+50k each time). Run once in Supabase > SQL Editor.
create or replace function _rebirth_cost(p_done int) returns numeric
language sql immutable as $$ select 100000::numeric + 50000 * coalesce(p_done, 0) $$;
notify pgrst, 'reload schema';
