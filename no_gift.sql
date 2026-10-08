-- Jambling: turn off gifting. Run once in Supabase > SQL Editor.
create or replace function gift_coins(p_to text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Gifting is turned off';
end $$;
notify pgrst, 'reload schema';
