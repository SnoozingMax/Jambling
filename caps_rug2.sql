-- Jambling: Coin Flip max bet 5m; Ride rug tiers 15%% base / 25%% >1m / 30%% >100m / 40%% >1b. Run once in Supabase > SQL Editor.

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
  if p_bet > 5000000 then raise exception 'Max Coin Flip bet is 5,000,000'; end if;
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

create or replace function ride_feed(p_round uuid, p_from int) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  rd ride_rounds;
  k int;
  a int;
  c ride_paths;
  g record;
begin
  select * into rd from ride_rounds where id = p_round and user_id = auth.uid();
  if not found then raise exception 'Round not found'; end if;
  k := case when rd.status = 'live' then _ride_k(rd) else rd.last_step end;
  a := greatest(coalesce(p_from, 0), 0);
  if a > k then return json_build_object('k', k, 'from', a, 'p', '[]'::json, 'ev', '[]'::json, 'heat', '[]'::json, 'live', rd.status = 'live'); end if;
  k := least(k, a + 300);
  -- the chart is worked out a minute ahead and kept here (never sent), so each poll is just a slice
  select * into c from ride_paths where round_id = rd.id;
  if not found or array_length(c.p, 1) < k + 1 then
    g := _ride_gen(rd.seed, k + 600, rd.boost_steps, rd.bad_steps, rd.rush_steps,
                   case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end);
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
    'live', rd.status = 'live');
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
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';
