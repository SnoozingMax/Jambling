-- Jambling: re-create flip_coin (if Coin Flip says the function can't be found) and reload the API cache. Run in Supabase > SQL Editor.
create table if not exists coin_flips (
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null, pick text not null, result text not null, won boolean not null,
  delta numeric not null, created_at timestamptz not null default now()
);
alter table profiles add column if not exists murphy boolean not null default false;

-- coin flip: losing a bet of 1 billion or more unlocks Murphy's Law
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
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := p_pick;   -- good luck: always win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.90 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 90% win
  else res := case when random() < (case when _rigged(auth.uid()) then 0.44 else 0.5 end) then p_pick when p_pick = 'heads' then 'tails' else 'heads' end; end if;   -- rigged players: 44% win
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into coin_flips (user_id, bet, pick, result, won, delta) values (auth.uid(), p_bet, p_pick, res, won, delta);
  if not won and p_bet >= 1000000000 then update profiles set murphy = true where id = auth.uid(); end if;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta, 'murphy', (not won and p_bet >= 1000000000));
end $$;

grant execute on function flip_coin(numeric, text) to authenticated;
notify pgrst, 'reload schema';
