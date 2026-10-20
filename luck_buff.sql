-- Jambling: good luck = guaranteed win on every house game; rush hour buffed (still not guaranteed). Run once in Supabase > SQL Editor.

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
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

create or replace function mines_pick(p_id uuid, p_tile int) returns json
language plpgsql security definer set search_path = public as $$
declare r mines_rounds; chance numeric; bal numeric;
begin
  select * into r from mines_rounds where id = p_id and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if r.status <> 'live' then raise exception 'Round is over'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Bad tile'; end if;
  if p_tile = any(r.revealed) then return _mines_view(r); end if;

  chance := _mines_chance(r.mines, cardinality(r.revealed));
  if _bad_luck_now(auth.uid()) then chance := 1;           -- bad luck: always a bomb
  else
    if _rush_now() then chance := chance * 0.25; end if;   -- rush hour: quarter the risk
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := 0; end if;   -- good luck: never a bomb
  end if;

  if random() < chance then
    update mines_rounds set status = 'boom', payout = 0, bombs = _mines_fill(r, array[p_tile]) where id = r.id returning * into r;
    select balance into bal from profiles where id = auth.uid();
    return _mines_view(r, bal);
  end if;

  update mines_rounds set revealed = revealed || p_tile where id = r.id returning * into r;
  if cardinality(r.revealed) >= 25 - r.mines or _mines_payout(r) >= r.bet + 20000000 then
    return _mines_cash(r);
  end if;
  return _mines_view(r);
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
  elsif exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) > 0 order by random() limit 1;   -- good luck: always land a winner
  else
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;   -- rush hour: a loss gets two free re-spins
    if _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then r := floor(random() * 37)::int; end if;
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

create or replace function bj_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric; h bj_hands; d int[]; dt int; is_bj boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current hand first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid();

  select array_agg(c order by random()) into d from generate_series(0, 51) c;
  -- bad luck: you get 16, dealer gets 20, and the next cards are all 10s
  if (select badluck_until > clock_timestamp() from profiles where id = auth.uid()) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            six int := (select c from unnest(d) c where c % 13 = 5 limit 1);
            picked int[];
    begin
      picked := array[tens[1], tens[2], six, tens[3]];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by (c % 13 >= 9) desc, random());
    end;
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then   -- good luck: player blackjack, dealer can't match
    declare ace int := (select c from unnest(d) c where c % 13 = 0 limit 1);
            ten int := (select c from unnest(d) c where c % 13 >= 9 limit 1);
            w1 int := (select c from unnest(d) c where c % 13 in (3,4,5) limit 1);
            w2 int := (select c from unnest(d) c where c % 13 in (3,4,5) and c <> (select c from unnest(d) c where c % 13 in (3,4,5) limit 1) limit 1);
            picked int[];
    begin
      picked := array[ace, w1, ten, w2];   -- player: ace+ten (blackjack); dealer: two low cards
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by random());
    end;
  elsif (select rush_until > clock_timestamp() from site_state where id = 1) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            good int := (select c from unnest(d) c where c % 13 in (0, 8) or c % 13 >= 9 limit 1 offset 1);
            weak int := (select c from unnest(d) c where c % 13 in (3, 4, 5) limit 1);
            picked int[];
    begin
      if good = tens[1] then good := tens[2]; end if;
      picked := array[tens[1], weak, good];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by random());
      d := d[1:3] || d[4:];
    end;
  end if;
  insert into bj_hands (user_id, bet, deck, player, dealer, pvals)
    values (auth.uid(), p_bet, d[5:], array[d[1], d[3]], array[d[2], d[4]], array[_bj_val(d[1]), _bj_val(d[3])])
    returning * into h;

  is_bj := _bj_total(h.player) = 21;          -- ace + ten is always blackjack
  dt := _bj_total(h.dealer);
  if is_bj then
    update bj_hands set pvals = array[coalesce(pvals[1], 11), coalesce(pvals[2], 11)] where id = h.id;
    h := _bj_settle(h.id, case when dt = 21 then 'push' else 'blackjack' end);
  elsif dt = 21 then
    h := _bj_settle(h.id, 'lose');
  end if;
  return _bj_view(h);
end $$;

notify pgrst, 'reload schema';
