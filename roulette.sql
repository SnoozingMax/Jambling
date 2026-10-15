-- Jambling: Roulette (European, single 0). Run once in Supabase > SQL Editor.
-- Bets: red/black, odd/even, 1-18/19-36 pay 1:1, dozens pay 2:1, a single number pays 35:1.
-- Max bet 100k, max win 5m. Bad luck = always loses. Rush hour = a losing spin gets one free re-spin.

create table if not exists roulette_spins (
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  bet numeric not null, kind text not null, num int, result int not null,
  payout numeric not null, created_at timestamptz not null default now()
);
create index if not exists roulette_spins_user on roulette_spins (user_id, created_at desc);
alter table roulette_spins enable row level security;   -- no policies: only functions touch it

create or replace function _roulette_win(kind text, num int, r int) returns int   -- profit multiple, 0 = lose
language sql immutable as $$
  select case
    when kind = 'number' then case when r = num then 35 else 0 end
    when r = 0 then 0
    when kind = 'red'   then case when r = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 1 else 0 end
    when kind = 'black' then case when not r = any(array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 1 else 0 end
    when kind = 'odd'   then case when r % 2 = 1 then 1 else 0 end
    when kind = 'even'  then case when r % 2 = 0 then 1 else 0 end
    when kind = 'low'   then case when r <= 18 then 1 else 0 end
    when kind = 'high'  then case when r >= 19 then 1 else 0 end
    when kind = 'dozen1' then case when r <= 12 then 2 else 0 end
    when kind = 'dozen2' then case when r between 13 and 24 then 2 else 0 end
    when kind = 'dozen3' then case when r >= 25 then 2 else 0 end
    else 0 end
$$;

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
    -- bad luck: land on a losing pocket
    select x into r from generate_series(0, 36) x where _roulette_win(p_kind, p_num, x) = 0 order by random() limit 1;
  elsif _rush_now() and _roulette_win(p_kind, p_num, r) = 0 then
    r := floor(random() * 37)::int;   -- rush hour: one free re-spin on a loss
  end if;

  mult := _roulette_win(p_kind, p_num, r);
  if mult > 0 then pay := least(p_bet + 5000000, round(p_bet + p_bet * mult * _luck(auth.uid()), 2)); end if;
  delta := pay - p_bet;
  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into roulette_spins (user_id, bet, kind, num, result, payout) values (auth.uid(), p_bet, p_kind, p_num, r, pay);
  return json_build_object('result', r, 'won', mult > 0, 'payout', pay, 'delta', delta, 'balance', bal);
end $$;

-- your last 12 results (for the history strip)
create or replace function roulette_recent() returns int[]
language sql stable security definer set search_path = public as $$
  select coalesce(array(select result from roulette_spins where user_id = auth.uid() order by id desc limit 12), '{}')
$$;

notify pgrst, 'reload schema';
