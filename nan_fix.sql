-- Jambling: fix NaN balances and stop it happening again. Run once in Supabase > SQL Editor (safe to run again).

-- 1) repair: broken balances go back to 1,000 (change the number if you want)
update profiles set balance = 1000 where balance = 'NaN'::numeric;

-- 2) a balance can never be saved as NaN or infinity: keep the old value instead
create or replace function _sane_balance() returns trigger
language plpgsql as $$
begin
  if new.balance = 'NaN'::numeric or new.balance = 'Infinity'::numeric or new.balance = '-Infinity'::numeric then
    new.balance := coalesce(old.balance, 0);
  end if;
  return new;
end $$;
drop trigger if exists sane_balance on profiles;
create trigger sane_balance before insert or update on profiles
for each row execute function _sane_balance();

-- 3) boosts stack up to 30 minutes max (much longer and the chart number overflows)
create or replace function admin_boost(p_user text) returns json
language plpgsql security definer set search_path = public as $$
declare
  them uuid; them_name text; until timestamptz;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles
     set boost_until = least(greatest(coalesce(boost_until, clock_timestamp()), clock_timestamp()) + interval '5 minutes',
                             clock_timestamp() + interval '30 minutes')
   where id = them returning boost_until into until;
  return json_build_object('user', them_name, 'until', until);
end $$;

-- 4) a Ride payout that overflows is capped instead of breaking
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

  path := _ride_path(rd.seed, a, rd.boost_steps);
  for i in 1 .. coalesce(array_length(h, 1), 0) / 2 loop
    m := m * 0.99 * path[h[2*i] + 1] / path[h[2*i - 1] + 1];   -- 1% fee per hold
  end loop;
  if m <> m then m := 1; end if;                                -- NaN: give the bet back
  m := least(m, 1e15);                                          -- overflow guard

  pay := round((rd.bet * m)::numeric, 2);
  if pay > rd.bet then pay := round(rd.bet + (pay - rd.bet) * (1 + 0.1 * coalesce((select rebirths from profiles where id = rd.user_id), 0)), 2); end if;  -- rebirth luck
  update ride_rounds set status = 'done', holds = h, holding = false, last_step = a, mult = m, payout = pay where id = rd.id;
  update profiles set balance = balance + pay where id = rd.user_id returning balance into bal;
  return json_build_object('payout', pay, 'mult', m, 'balance', bal, 'step', a, 'bet', rd.bet);
end $$;
revoke execute on function _ride_finish(uuid, int) from public, anon, authenticated;

-- refill is also blocked while you have a 1v1 going
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from crash_rounds where user_id = auth.uid() and status = 'live'
               and extract(epoch from clock_timestamp() - started_at) < ln(crash_point) / 0.09)
     or exists (select 1 from ride_rounds where user_id = auth.uid() and status = 'live')
     or exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live')
     or exists (select 1 from pvp_matches where (a = auth.uid() or b = auth.uid()) and status in ('pending', 'live')) then
    raise exception 'Finish your current game before refilling';
  end if;
  update profiles set balance = 100 where id = auth.uid() and balance < 10 returning balance into bal;
  if bal is null then raise exception 'Refill only works under 10 coins'; end if;
  return json_build_object('balance', bal);
end $$;


select username, balance from profiles order by balance desc limit 3;
notify pgrst, 'reload schema';
