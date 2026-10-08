-- Jambling: no max bet on Ride (bet up to your whole balance). Run once in Supabase > SQL Editor.

drop function if exists ride_start(numeric);
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
  select greatest(0, floor(extract(epoch from (rush_until - clock_timestamp())) / 0.1))::int into rush
    from site_state where id = 1 and rush_until > clock_timestamp();
  insert into ride_rounds (user_id, bet, seed, boost_steps, bad_steps, rush_steps)
    values (auth.uid(), p_bet, sd, coalesce(bs, 0), coalesce(bad, 0), coalesce(rush, 0)) returning id into rid;
  return json_build_object('round_id', rid, 'seed', sd, 'balance', bal, 'boost_steps', coalesce(bs, 0), 'bad_steps', coalesce(bad, 0), 'rush_steps', coalesce(rush, 0));
end $$;

notify pgrst, 'reload schema';
