-- Jambling: Coin Flip max bet 1,000,000. Run once in Supabase > SQL Editor.

create or replace function flip_coin(p_bet numeric, p_pick text) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  res text;
  won boolean;
  delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000 then raise exception 'Max Coin Flip bet is 1,000,000'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip (max bet 1m)

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

notify pgrst, 'reload schema';
