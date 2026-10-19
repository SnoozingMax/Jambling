-- Jambling: fix bad-luck Ride exploit (crash then recover). Bad luck now curses the whole round and can't profit.
-- Run once in Supabase > SQL Editor.

create or replace function ride_start(p_bet numeric, p_ver int) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  rid uuid;
  bs int;
  bad int;
  rush int;
  sd bigint := floor(random() * 2147483645)::bigint + 1;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_ver is distinct from ride_version() then raise exception 'Ride was updated. Refresh the page.'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;

  perform ride_cleanup();

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  select greatest(0, floor(extract(epoch from (boost_until - clock_timestamp())) / 0.1))::int into bs
    from profiles where id = auth.uid() and boost_until > clock_timestamp();
  select greatest(0, floor(extract(epoch from (badluck_until - clock_timestamp())) / 0.1))::int into bad
    from profiles where id = auth.uid() and badluck_until > clock_timestamp();
  if coalesce(bad, 0) > 0 then bad := 1000000000; end if;   -- bad luck curses the whole round, so no crash-and-recover exploit
  select greatest(0, floor(extract(epoch from (rush_until - clock_timestamp())) / 0.1))::int into rush
    from site_state where id = 1 and rush_until > clock_timestamp();
  insert into ride_rounds (user_id, bet, seed, boost_steps, bad_steps, rush_steps)
    values (auth.uid(), p_bet, sd, coalesce(bs, 0), coalesce(bad, 0), coalesce(rush, 0)) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal, 'boost_steps', coalesce(bs, 0), 'bad_steps', coalesce(bad, 0), 'rush_steps', coalesce(rush, 0));
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
  if rd.bad_steps > 0 then m := least(m, 1.0); end if;         -- bad luck: never profit

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.05 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  delete from ride_paths where round_id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;

notify pgrst, 'reload schema';
