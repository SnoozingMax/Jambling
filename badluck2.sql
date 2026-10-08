-- Jambling: harsher Bad luck. Run once in Supabase > SQL Editor (safe to run again).
-- Ride: no more pumps, just chop then a rug to 40% every 0.6s.
-- Rocket: blows up instantly (1.00x). Coin flip + Blackjack were already always-lose.

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
    if ev_left = 0 and rug = 0 and u3 > (case when i <= p_rush then 0.98 else 0.99 end) then
      if u2 < (case when i <= p_rush then 0.8 else 0.45 end) then   -- rush hour: way more pumps, no rugs                                   -- pump: +65% to +170% over 3-7s. 15% rug-pull partway
        ev_dir := 1;
        d := 30 + floor(u1 * 41)::int;
        size := 0.5 + 0.5 * (u1 * 53 - floor(u1 * 53));
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
        size := 0.15 + 0.25 * (u1 * 53 - floor(u1 * 53));
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


create or replace function ride_version() returns int language sql immutable as $$ select 35 $$;

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

  update crash_rounds set status = 'crashed' where user_id = auth.uid() and status = 'live';

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then cp := 1.00;          -- bad luck: blows up instantly
  elsif _rush_now() then                                     -- rush hour: 1.5x minimum, ~5x typical
    r := random();
    cp := least(1000, greatest(1.5, floor(2.5 / (1 - r) * 100) / 100))::numeric;
  else
    r := random();
    cp := least(1000, greatest(1.00, floor(0.97 / (1 - r) * 100) / 100))::numeric;
  end if;

  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into crash_rounds (user_id, bet, crash_point) values (auth.uid(), p_bet, cp) returning id into rid;

  return json_build_object('round_id', rid, 'balance', bal);
end $$;

notify pgrst, 'reload schema';
