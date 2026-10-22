-- Jambling: Aurora grants the luck of 100 rebirths (hidden from counts/titles/leaderboard). Run once in Supabase > SQL Editor.

create or replace function _luck(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select 1 + 0.05 * (coalesce((select rebirths from profiles where id = p_uid), 0)
                     + case when coalesce((select gifted from profiles where id = p_uid), false) then 100 else 0 end)
$$;

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
  luck := _luck(h.user_id);
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
    path := _ride_path(rd.seed, a, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                       case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
  end if;
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.98 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 2% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard
  if rd.bad_steps > 0 then m := least(m, 1.0); end if;         -- bad luck: never profit

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * _luck(rd.user_id), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';
