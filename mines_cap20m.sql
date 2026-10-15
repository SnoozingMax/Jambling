-- Jambling: Mines max win 20m. Run once in Supabase > SQL Editor (after mines.sql and mines2.sql).

create or replace function _mines_payout(r mines_rounds) returns numeric
language sql stable security definer set search_path = public as $$
  select least(r.bet + 20000000,
               round(r.bet + r.bet * (_mines_mult(r.mines, cardinality(r.revealed)) - 1) * _luck(r.user_id), 2))
$$;
revoke execute on function _mines_payout(mines_rounds) from public, anon, authenticated;

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
  if cardinality(r.revealed) >= 25 - r.mines or _mines_payout(r) >= r.bet + 20000000 then
    return _mines_cash(r);
  end if;
  return _mines_view(r);
end $$;

notify pgrst, 'reload schema';
