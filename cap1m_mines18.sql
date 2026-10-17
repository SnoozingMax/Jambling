-- Jambling: Roulette & Mines max bet 1,000,000; Mines max 18 bombs. Run once in Supabase > SQL Editor.

create or replace function mines_start(p_bet numeric, p_mines int) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r mines_rounds;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from mines_rounds where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current Mines round first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 18 then raise exception 'Pick 1 to 18 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r int; mult int; pay numeric := 0; delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000 then raise exception 'Max bet is 1,000,000'; end if;
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

notify pgrst, 'reload schema';
