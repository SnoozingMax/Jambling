-- Jambling: Refill (to 100). Run once in Supabase > SQL Editor (safe to run again).
-- Only when you're under 10 coins AND not in the middle of a Rocket, Ride or Blackjack round.

create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from crash_rounds where user_id = auth.uid() and status = 'live'
               and exp(0.09 * extract(epoch from clock_timestamp() - started_at)) < crash_point)
     or exists (select 1 from ride_rounds where user_id = auth.uid() and status = 'live')
     or exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current game before refilling';
  end if;
  update profiles set balance = 100 where id = auth.uid() and balance < 10 returning balance into bal;
  if bal is null then raise exception 'Refill only works under 10 coins'; end if;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';
