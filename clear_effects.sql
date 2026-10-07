-- Jambling: remove Boost / Bad luck (undo accidents). Run once in Supabase > SQL Editor (safe to run again).
-- Also cancels the player's in-progress Ride, Rocket and Blackjack rounds and refunds those bets.

create or replace function clear_effect(p_user text, p_kind text) returns json
language plpgsql security definer set search_path = public as $$
declare role text := my_role(); them uuid; them_name text; refunded numeric := 0; x numeric;
begin
  if role is null then raise exception 'Moderators only'; end if;
  if p_kind not in ('boost', 'bad') then raise exception 'Unknown effect'; end if;
  if p_kind = 'boost' and role <> 'admin' then raise exception 'Only admins can remove boosts'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;

  if p_kind = 'boost' then update profiles set boost_until = null where id = them;
  else update profiles set badluck_until = null where id = them; end if;

  -- refund anything in progress so the effect can't still hit (or pay) them
  select coalesce(sum(bet), 0) into x from ride_rounds where user_id = them and status = 'live';
  refunded := refunded + x;
  update ride_rounds set status = 'done', payout = bet, holding = false where user_id = them and status = 'live';
  select coalesce(sum(bet), 0) into x from crash_rounds where user_id = them and status = 'live';
  refunded := refunded + x;
  update crash_rounds set status = 'cashed', cashout = 1 where user_id = them and status = 'live';
  select coalesce(sum(bet), 0) into x from bj_hands where user_id = them and status = 'live';
  refunded := refunded + x;
  update bj_hands set status = 'done', result = 'void', payout = bet where user_id = them and status = 'live';
  update profiles set balance = balance + refunded where id = them;

  return json_build_object('user', them_name, 'kind', p_kind, 'refunded', refunded);
end $$;

notify pgrst, 'reload schema';
