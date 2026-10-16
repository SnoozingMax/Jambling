-- Jambling: boost (good luck) on Roulette + remove Rocket. Run once in Supabase > SQL Editor (after roulette.sql).
-- Roulette effects:  bad luck = always loses.  Rush hour = a losing spin gets 1 free re-spin.
--                    Boost (good luck) = a losing spin gets 1 free re-spin (stacks with rush hour: up to 2).
-- Mines effects (already in): bad luck = every tile is a bomb. Rush hour and boost each halve the bomb chance.

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
  if p_kind not in ('red','black','odd','even','low','high','dozen1','dozen2','dozen3','number') then raise exception 'Pick a bet'; end if;
  if p_kind = 'number' and (p_num is null or p_num < 0 or p_num > 36) then raise exception 'Pick a number 0-36'; end if;
  if p_kind <> 'number' then p_num := null; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  r := floor(random() * 37)::int;
  if _bad_luck_now(auth.uid()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  else
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp())
       and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

-- Rocket removed: no new rounds (anyone mid-round can still cash out)
create or replace function crash_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Rocket was removed. Refresh the page.';
end $$;

notify pgrst, 'reload schema';
