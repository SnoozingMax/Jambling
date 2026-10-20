-- Jambling: hidden per-player slight bad luck (rigged flag) - applied to siddthatridegod. Run once in Supabase > SQL Editor.

alter table profiles add column if not exists rigged boolean not null default false;
create or replace function _rigged(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select rigged from profiles where id = p_uid), false)
$$;
update profiles set rigged = true where lower(username) = 'siddthatridegod';

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
    if _rigged(auth.uid()) then chance := least(1, chance * 1.2); end if;   -- rigged: a touch more bomb risk
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
  if _rigged(auth.uid()) and mult > 0 and random() < 0.12 then   -- rigged: quietly turn some wins into losses
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
    mult := 0;
  end if;
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
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
                   least(0.9, (case when rd.bet > 1000000000 then 0.40 when rd.bet > 100000000 then 0.30 when rd.bet > 1000000 then 0.25 else 0.15 end) + case when _rigged(rd.user_id) then 0.07 else 0 end));
    insert into ride_paths values (rd.id, g.px, g.evs, g.heats)
      on conflict (round_id) do update set p = excluded.p, ev = excluded.ev, heat = excluded.heat
      returning * into c;
  end if;
  return json_build_object('k', k, 'from', a,
    'p', to_json(c.p[a + 1 : k + 1]), 'ev', to_json(c.ev[a + 1 : k + 1]), 'heat', to_json(c.heat[a + 1 : k + 1]),
    'live', rd.status = 'live');
end $$;

notify pgrst, 'reload schema';
