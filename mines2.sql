-- Jambling: Mines high risk high reward. Run once in Supabase > SQL Editor (after mines.sql).
-- Every tap is 40% more likely to be a bomb, and the multiplier grows to match (house edge still 3%).

-- chance the next tap is a bomb, with k tiles already open
create or replace function _mines_chance(m int, k int) returns numeric
language sql immutable as $$
  select least(0.96, 1.4 * m / (25 - k)::numeric)
$$;

create or replace function _mines_mult(m int, k int) returns numeric
language sql immutable as $$
  select case when k <= 0 then 1::numeric
    else round(floor(0.97 * exp(coalesce((select sum(-ln(1 - _mines_chance(m, i))) from generate_series(0, k - 1) i), 0)) * 100) / 100, 2) end
$$;

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
    if _rush_now() then chance := chance * 0.5; end if;    -- rush hour: half the risk
    if exists (select 1 from profiles where id = auth.uid() and boost_until > clock_timestamp()) then chance := chance * 0.5; end if;
  end if;

  if random() < chance then
    update mines_rounds set status = 'boom', payout = 0, bombs = _mines_fill(r, array[p_tile]) where id = r.id returning * into r;
    select balance into bal from profiles where id = auth.uid();
    return _mines_view(r, bal);
  end if;

  update mines_rounds set revealed = revealed || p_tile where id = r.id returning * into r;
  if cardinality(r.revealed) >= 25 - r.mines or _mines_payout(r) >= r.bet + 5000000 then
    return _mines_cash(r);
  end if;
  return _mines_view(r);
end $$;

notify pgrst, 'reload schema';
