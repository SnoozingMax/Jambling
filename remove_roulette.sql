-- Jambling: roulette removed from the site. Make its RPCs refuse so the anon key can't call them. Run once.
create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Roulette has been removed'; end $$;

create or replace function roulette_recent() returns int[]
language plpgsql security definer set search_path = public as $$
begin return '{}'::int[]; end $$;

notify pgrst, 'reload schema';
