-- Jambling: shop removed. Make the shop RPCs refuse so nobody can call them with the anon key. Run once.
create or replace function shop_rush() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'The shop has been removed'; end $$;

create or replace function shop_boost() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'The shop has been removed'; end $$;

notify pgrst, 'reload schema';
