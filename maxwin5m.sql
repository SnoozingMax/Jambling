-- Jambling: max win 5,000,000 per round on every game. Run once in Supabase > SQL Editor.

create or replace function _ride_finish(p_id uuid, a int) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd ride_rounds;
  h int[];
  path float8[];
  m float8 := 1;
  pay numeric;
  bal numeric;
begin
  select * into rd from ride_rounds where id = p_id for update;
  if rd.status <> 'live' then return json_build_object('payout', rd.payout); end if;
  a := greatest(a, rd.last_step);
  h := rd.holds;
  if rd.holding then h := h || a; end if;

  select p into path from ride_paths where round_id = rd.id;              -- the exact chart the player was shown
  if path is null or array_length(path, 1) < a + 1 then
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  pay := least(pay, rd.bet + 5000000);                         -- max win 5m per round (RIDE_MAX_WIN in index.html)
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;
revoke execute on function _ride_finish(uuid, int) from public, anon, authenticated;

create or replace function crash_cashout(p_round uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  rd crash_rounds;
  m numeric;
  payout numeric;
  bal numeric;
begin
  select * into rd from crash_rounds where id = p_round and user_id = auth.uid() for update;
  if not found then raise exception 'Round not found'; end if;
  if rd.status <> 'live' then raise exception 'Round over'; end if;

  m := floor(exp(0.09 * extract(epoch from clock_timestamp() - rd.started_at)) * 100) / 100;

  if m >= rd.crash_point then
    update crash_rounds set status = 'crashed' where id = rd.id;
    select balance into bal from profiles where id = auth.uid();
    return json_build_object('won', false, 'crash_point', rd.crash_point, 'balance', bal);
  end if;

  payout := round(rd.bet + rd.bet * (m - 1) * _luck(auth.uid()), 2);
  payout := least(payout, rd.bet + 5000000);   -- max win 5m per round
  update crash_rounds set status = 'cashed', cashout = m where id = rd.id;
  update profiles set balance = balance + payout where id = auth.uid() returning balance into bal;

  return json_build_object('won', true, 'multiplier', m, 'payout', payout, 'balance', bal, 'crash_point', rd.crash_point);
end $$;

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
  if p_bet > 500000 then raise exception 'Max bet is 500,000'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then least(round(p_bet * _luck(auth.uid()), 2), 5000000) else -p_bet end;   -- max win 5m

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

create or replace function _bj_settle(p_id uuid, p_result text default null) returns bj_hands
language plpgsql security definer set search_path = public as $$
declare
  h bj_hands; pt int; dt int; res text; pay numeric := 0; luck numeric;
begin
  select * into h from bj_hands where id = p_id for update;
  if h.status <> 'live' then return h; end if;
  pt := _bj_sum(h.pvals);
  res := p_result;
  if res is null then
    if pt > 21 then res := 'bust';
    else
      while _bj_total(h.dealer) < 17 loop h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:]; end loop;
      dt := _bj_total(h.dealer);
      res := case when dt > 21 or pt > dt then 'win' when pt = dt then 'push' else 'lose' end;
    end if;
  end if;
  luck := 1 + 0.1 * coalesce((select rebirths from profiles where id = h.user_id), 0);
  pay := case res
    when 'blackjack' then round(h.bet + h.bet * 1.5 * luck, 2)
    when 'win'       then round(h.bet + h.bet * luck, 2)
    when 'push'      then h.bet
    else 0 end;
  pay := least(pay, h.bet + 5000000);   -- max win 5m per hand
  update bj_hands set dealer = h.dealer, deck = h.deck, status = 'done', result = res, payout = pay where id = h.id
    returning * into h;
  update profiles set balance = balance + pay where id = h.user_id;
  return h;
end $$;

notify pgrst, 'reload schema';
