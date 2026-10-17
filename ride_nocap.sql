-- Jambling: Ride profit cap removed (no max win, matches the uncapped bet). Run once in Supabase > SQL Editor.

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
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';
