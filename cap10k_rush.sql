-- Jambling: max bet 10,000 on every game + rush hour toned down a little.
-- Run once in Supabase > SQL Editor (safe to run again).

drop function if exists _ride_path(bigint, int);
drop function if exists _ride_path(bigint, int, int);
drop function if exists _ride_path(bigint, int, int, int);
create or replace function _ride_path(p_seed bigint, n int, p_boost int default 0, p_bad int default 0, p_rush int default 0) returns float8[]
language plpgsql immutable as $$
declare
  s bigint := p_seed;
  v float8 := 0;
  p float8 := 100;
  heat float8 := 1;
  vol float8;
  u1 float8; u2 float8; u3 float8;
  ev_left int := 0; ev_dir float8 := 0; d int := 0;
  size float8 := 0; w float8 := 1; x float8; drift float8;
  cut int := -1; rug int := 0; base float8 := 100;
  k int; ev int; done boolean;
  arr float8[] := array[100.0];
begin
  for i in 1..n loop
    s := (s * 48271) % 2147483647; u1 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u2 := s::float8 / 2147483647;
    s := (s * 48271) % 2147483647; u3 := s::float8 / 2147483647;
    if u3 < 0.004 then heat := 3; end if;                 -- wild phase
    heat := 1 + (heat - 1) * 0.97;
    vol := heat * 2;
    if i <= p_bad then                                    -- bad luck: fake chop, then a rug to 40%, every 0.6s
      k := (i - 1) % 6;
      if k < 3 then p := p * exp((u2 - 0.5) * 0.01);
      else p := p * exp(ln(0.4) / 3);
      end if;
      ev_left := 0; rug := 0; v := 0;
      p := least(greatest(p, 1e-200), 1e200);
      arr := arr || p;
      continue;
    end if;
    if i <= p_boost then                                  -- admin boost: fast nonstop pump (~+22%/s), no dumps
      p := least(p * exp(0.02 + (u2 - 0.5) * 0.02), 1e200);
      ev_left := 0; rug := 0; v := 0;
      arr := arr || p;
      continue;
    end if;
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.97 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.88 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := case when i <= p_rush then 0.7 + 0.6 * (u1 * 53 - floor(u1 * 53)) else 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53)) end;   -- rush: bigger pumps
        w := 0;
        for j in 1..d loop x := (j - 0.5) / d; w := w + x * (1 - x); end loop;
        base := p;
        if i > p_rush and (u1 * 97 - floor(u1 * 97)) < 0.15 then
          cut := 3 + floor((u1 * 331 - floor(u1 * 331)) * (d - 3))::int;
        else
          cut := -1;
        end if;
      else                                                -- dump: -14% to -33%, random length, hits hardest first
        ev_dir := -1;
        d := 5 + floor((u1 * 13 - floor(u1 * 13)) * 18)::int;
        size := (case when i <= p_rush then 0.7 else 1 end) * (0.15 + 0.25 * (u1 * 53 - floor(u1 * 53)));   -- rush: half-size dumps
        w := (d * (d + 1))::float8 / 2;
      end if;
      ev_left := d;
    end if;
    ev := 0; drift := 0; done := false;
    if ev_left > 0 then
      k := d - ev_left + 1;
      if ev_dir > 0 then
        if k = cut then
          ev_left := 0; rug := 3;
        else
          x := (k - 0.5) / d; drift := size * (x * (1 - x)) / w; ev := 1;
          ev_left := ev_left - 1;
        end if;
      else
        p := p * exp(-size * (d - k + 1) / w + (u2 - 0.5) * 0.012); v := 0; ev := -1;
        ev_left := ev_left - 1; done := true;
      end if;
    end if;
    if not done and rug > 0 and ev = 0 then              -- rug pull: crash to half of where the pump started
      p := p * exp(ln(base * 0.5 / p) / rug);
      rug := rug - 1; v := 0; done := true;
    end if;
    if not done then                                      -- normal chop keeps going during pumps
      v := 0.8 * v + (u1 - 0.5) * 0.009 * vol - 0.0007 * ln(p / 100);
      p := p * exp(v + (u2 - 0.5) * 0.035 * vol + drift);
    end if;
    p := least(greatest(p, 1e-200), 1e200);                -- never overflow
    arr := arr || p;
  end loop;
  return arr;
end $$;

create or replace function ride_version() returns int language sql immutable as $$ select 37 $$;

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
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;

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
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;
  elsif _rush_now() then res := case when random() < 0.80 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 80% win
  else res := case when random() < 0.5 then 'heads' else 'tails' end; end if;
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

create or replace function crash_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  cp numeric;
  rid uuid;
  r float8;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then cp := 1.00;          -- bad luck: blows up instantly
  elsif _rush_now() then                                     -- rush hour: 1.8x minimum, ~7x typical
    r := random();
    cp := least(1000, greatest(1.8, floor(3.5 / (1 - r) * 100) / 100))::numeric;
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric;
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;

  return json_build_object('round_id', rid, 'balance', bal);
end $$;

create or replace function bj_start(p_bet numeric) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric; h bj_hands; d int[]; dt int; is_bj boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current hand first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 10000 then raise exception 'Max bet is 10,000'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid();

  select array_agg(c order by random()) into d from generate_series(0, 51) c;
  -- bad luck: you get 16, dealer gets 20, and the next cards are all 10s
  if (select badluck_until > clock_timestamp() from profiles where id = auth.uid()) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            six int := (select c from unnest(d) c where c % 13 = 5 limit 1);
            picked int[];
    begin
      picked := array[tens[1], tens[2], six, tens[3]];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by (c % 13 >= 9) desc, random());
    end;
  elsif (select rush_until > clock_timestamp() from site_state where id = 1) then
    declare tens int[] := array(select c from unnest(d) c where c % 13 >= 9);
            good int := (select c from unnest(d) c where c % 13 in (0, 8) or c % 13 >= 9 limit 1 offset 1);
            weak int := (select c from unnest(d) c where c % 13 in (3, 4, 5) limit 1);
            picked int[];
    begin
      if good = tens[1] then good := tens[2]; end if;
      picked := array[tens[1], weak, good];
      d := picked || array(select c from unnest(d) c where not (c = any(picked)) order by random());
      d := d[1:3] || d[4:];
    end;
  end if;
  insert into bj_hands (user_id, bet, deck, player, dealer, pvals)
    values (auth.uid(), p_bet, d[5:], array[d[1], d[3]], array[d[2], d[4]], array[_bj_val(d[1]), _bj_val(d[3])])
    returning * into h;

  is_bj := _bj_total(h.player) = 21;          -- ace + ten is always blackjack
  dt := _bj_total(h.dealer);
  if is_bj then
    update bj_hands set pvals = array[coalesce(pvals[1], 11), coalesce(pvals[2], 11)] where id = h.id;
    h := _bj_settle(h.id, case when dt = 21 then 'push' else 'blackjack' end);
  elsif dt = 21 then
    h := _bj_settle(h.id, 'lose');
  end if;
  return _bj_view(h);
end $$;

notify pgrst, 'reload schema';
