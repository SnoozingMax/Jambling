-- Jambling: bring Rocket back and make it respect every effect. Run once in Supabase > SQL Editor.
--   Bad luck  -> crashes instantly (you lose)
--   Good luck -> flies to 1000x, so any cash-out is a win
--   Rush hour -> much higher crash points (1.8x floor, ~7x typical)
--   Rebirths  -> multiply your winnings (via _luck, applied on cash-out)

create or replace function crash_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; cp numeric; rid uuid; r float8;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 100000 then raise exception 'Max bet is 100,000'; end if;

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then
    cp := 1.00;                                                        -- bad luck: blows up instantly
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then
    cp := 1000;                                                        -- good luck: flies high, any cash-out wins
  elsif _rush_now() then
    r := random();
    cp := least(1000, greatest(1.8, floor(3.5 / (1 - r) * 100) / 100))::numeric;   -- rush hour: 1.8x floor, ~7x typical
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric; -- normal
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;
  return json_build_object('round_id', rid, 'balance', bal);
end $$;
revoke execute on function crash_start(numeric) from anon;

-- cash-out: winnings scale with rebirths (_luck), capped at +5m per round
create or replace function crash_cashout(p_round uuid) returns json
language plpgsql security definer set search_path = public as $$
declare rd crash_rounds; m numeric; payout numeric; bal numeric;
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
revoke execute on function crash_cashout(uuid) from anon;

notify pgrst, 'reload schema';
