-- ============================================================
-- Jambling: all pending changes in one file. Run once in Supabase > SQL Editor.
-- Includes: restore Rocket, Mines bet 1b, Tester title, remove Steal/Poison,
--   admins can give rebirths, better logs, single admin-or-mod role,
--   demote Bebewill to mod, disable removed Shop & Roulette RPCs.
-- ============================================================


-- ========================================================================
-- >>> restore_rocket.sql
-- ========================================================================
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

-- ========================================================================
-- >>> mines_bet1b.sql
-- ========================================================================
-- Jambling: raise the Mines max bet to 1 billion. Run once in Supabase > SQL Editor.
create or replace function mines_start(p_bet numeric, p_mines int) returns json
language plpgsql security definer set search_path = public as $$
declare bal numeric; r mines_rounds;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from mines_rounds where user_id = auth.uid() and status = 'live') then
    raise exception 'Finish your current Mines round first';
  end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_bet > 1000000000 then raise exception 'Max bet is 1,000,000,000'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 15 then raise exception 'Pick 1 to 15 bombs'; end if;
  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;
  update profiles set balance = balance - p_bet where id = auth.uid() returning balance into bal;
  insert into mines_rounds (user_id, bet, mines) values (auth.uid(), p_bet, p_mines) returning * into r;
  return _mines_view(r, bal);
end $$;

notify pgrst, 'reload schema';

-- ========================================================================
-- >>> tester_title.sql
-- ========================================================================
-- Jambling: new "Tester" title (rainbow outlined, animated) + remove Steal/Poison from the shop.
-- Run once in Supabase > SQL Editor.

-- Tester title: a boolean on profiles, granted by max only (like Aurora).
alter table profiles add column if not exists tester boolean not null default false;

create or replace function admin_gift_tester(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the Tester title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set tester = p_on where id = them;
  return json_build_object('user', them_name, 'tester', p_on);
end $$;
revoke execute on function admin_gift_tester(text, boolean) from anon;
grant execute on function admin_gift_tester(text, boolean) to authenticated;

-- Remove Steal + Poison from the shop: make the RPCs refuse so no old client can still buy them.
create or replace function shop_steal(p_target text) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Steal has been removed from the shop'; end $$;

create or replace function shop_poison() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Poison has been removed from the shop'; end $$;

create or replace function poison_pulse() returns json
language plpgsql security definer set search_path = public as $$
begin return json_build_object('ok', true); end $$;

notify pgrst, 'reload schema';

-- ========================================================================
-- >>> logs_v2.sql
-- ========================================================================
-- Jambling: admins can give rebirths + much better staff/gift logging. Run once in Supabase > SQL Editor.
-- (Order-independent: safe to run before or after tester_title.sql / shop_daily.sql.)

-- make sure the tester column exists before the trigger below references it
alter table profiles add column if not exists tester boolean not null default false;

-- 1) Admins (not just max) can give rebirths
create or replace function admin_give_rebirths(p_user text, p_n int) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; rb int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_n is null or p_n <= 0 then raise exception 'Enter how many'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set rebirths = rebirths + p_n where id = them returning rebirths into rb;
  return json_build_object('user', them_name, 'rebirths', rb);
end $$;
revoke execute on function admin_give_rebirths(text, int) from anon;

-- 2) Log role changes (admin/mod promotions + removals) by anyone, so max has a record
create or replace function _watch_roles() returns trigger
language plpgsql security definer set search_path = public as $$
declare uname text; role text := case tg_table_name when 'admins' then 'admin' else 'mod' end;
begin
  if tg_op = 'INSERT' then
    select username into uname from profiles where id = new.user_id;
    perform _log_staff(uname, 'made ' || case when role = 'admin' then 'an admin' else 'a mod' end);
    return new;
  else
    select username into uname from profiles where id = old.user_id;
    perform _log_staff(uname, 'removed as ' || role);
    return old;
  end if;
end $$;
drop trigger if exists watch_admins on admins;
create trigger watch_admins after insert or delete on admins for each row execute function _watch_roles();
drop trigger if exists watch_mods on moderators;
create trigger watch_mods after insert or delete on moderators for each row execute function _watch_roles();

-- 3) Rewrite the profiles watcher: log title grants + leaderboard hides too, title changes by ANYONE (incl. max)
create or replace function _watch_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text[] := '{}'; actor uuid := auth.uid();
begin
  if tg_op = 'DELETE' then
    if _is_staff_not_owner() and old.id <> actor then
      perform _log_staff(old.username, 'deleted the account (had ' || to_char(old.balance, 'FM999,999,999,999,990') || ' coins)');
    end if;
    return old;
  end if;

  -- title grants: recorded no matter who does them (these are max-only, but max wants to see them)
  if new.id is distinct from actor then
    if new.gifted is distinct from old.gifted then
      perform _log_staff(new.username, case when new.gifted then 'granted the Aurora title' else 'removed the Aurora title' end);
    end if;
    if new.tester is distinct from old.tester then
      perform _log_staff(new.username, case when new.tester then 'granted the Tester title' else 'removed the Tester title' end);
    end if;
  end if;

  -- everything else: only non-owner admins/mods acting on someone else
  if not _is_staff_not_owner() or new.id = actor then return new; end if;
  if new.balance > old.balance then w := w || ('gave ' || to_char(new.balance - old.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.balance < old.balance then w := w || ('took ' || to_char(old.balance - new.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.username is distinct from old.username then w := w || ('renamed ' || old.username || ' -> ' || new.username); end if;
  if new.rebirths is distinct from old.rebirths then
    w := w || ((case when new.rebirths > old.rebirths then 'gave ' || (new.rebirths - old.rebirths) || ' rebirths'
                     else 'took ' || (old.rebirths - new.rebirths) || ' rebirths' end) || ' (now ' || new.rebirths || ')');
  end if;
  if new.badluck_until is distinct from old.badluck_until then
    w := w || (case when new.badluck_until is null or new.badluck_until < now() then 'removed bad luck' else 'gave bad luck' end);
  end if;
  if new.boost_until is distinct from old.boost_until and new.boost_until is null then w := w || 'removed boost'::text; end if;
  if new.board_hidden is distinct from old.board_hidden then w := w || (case when new.board_hidden then 'hid from leaderboard' else 'unhid from leaderboard' end); end if;
  if new.approved is distinct from old.approved then w := w || (case when new.approved then 'accepted from waiting room' else 'sent to waiting room' end); end if;
  if new.rejected_at is distinct from old.rejected_at and new.rejected_at is not null then w := w || 'rejected from waiting room'::text; end if;
  if array_length(w, 1) > 0 then perform _log_staff(new.username, array_to_string(w, ', ')); end if;
  return new;
end $$;
drop trigger if exists watch_profiles on profiles;
create trigger watch_profiles after update or delete on profiles for each row execute function _watch_profiles();

-- 4) Gift log: also return a running total so the client can show a summary
drop function if exists admin_gift_log(text);
create or replace function admin_gift_log(p_user text default null) returns table(at timestamptz, from_user text, to_user text, amount numeric, message text, total numeric, cnt bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    with rows as (
      select g.created_at, f.username as fu, t.username as tu, g.amount as amt, g.message as msg
      from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
      where coalesce(trim(p_user), '') = ''
         or lower(f.username) = lower(trim(p_user)) or lower(t.username) = lower(trim(p_user)))
    select r.created_at, r.fu, r.tu, r.amt, r.msg,
           sum(r.amt) over (), count(*) over ()
    from rows r order by r.created_at desc limit 200;
end $$;
revoke execute on function admin_gift_log(text) from anon;

notify pgrst, 'reload schema';

-- ========================================================================
-- >>> single_role.sql
-- ========================================================================
-- Jambling: a player can't be admin and mod at the same time. Run once in Supabase > SQL Editor.
-- Making someone an admin drops their mod role; making someone a mod drops their admin role. The owner stays admin.

create or replace function _one_role_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'admins' then
    delete from moderators where user_id = new.user_id;       -- admin supersedes mod
  else
    if exists (select 1 from site_owner where id = new.user_id) then
      raise exception 'The owner is always an admin, not a mod';
    end if;
    delete from admins where user_id = new.user_id;           -- mod drops admin
  end if;
  return new;
end $$;

drop trigger if exists one_role_admins on admins;
create trigger one_role_admins before insert on admins for each row execute function _one_role_only();
drop trigger if exists one_role_mods on moderators;
create trigger one_role_mods before insert on moderators for each row execute function _one_role_only();

-- clean up anyone who is currently both (admin wins)
delete from moderators where user_id in (select user_id from admins);

notify pgrst, 'reload schema';

-- ========================================================================
-- >>> demote_bebewill.sql
-- ========================================================================
-- Demote Bebewill from admin to mod. Run once in Supabase > SQL Editor.
-- (Works with or without single_role.sql: it removes admin and adds mod explicitly.)
do $$
declare uid uuid;
begin
  select id into uid from profiles where lower(username) = 'bebewill' order by created_at limit 1;
  if uid is null then raise exception 'No player named Bebewill'; end if;
  delete from admins where user_id = uid;
  insert into moderators (user_id) values (uid) on conflict do nothing;
end $$;

-- confirm (should show bebewill as mod only):
select p.username, 'admin' as role from admins a join profiles p on p.id = a.user_id where lower(p.username) = 'bebewill'
union all
select p.username, 'mod' from moderators m join profiles p on p.id = m.user_id where lower(p.username) = 'bebewill';

-- ========================================================================
-- >>> remove_shop.sql
-- ========================================================================
-- Jambling: shop removed. Make the shop RPCs refuse so nobody can call them with the anon key. Run once.
create or replace function shop_rush() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'The shop has been removed'; end $$;

create or replace function shop_boost() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'The shop has been removed'; end $$;

notify pgrst, 'reload schema';

-- ========================================================================
-- >>> remove_roulette.sql
-- ========================================================================
-- Jambling: roulette removed from the site. Make its RPCs refuse so the anon key can't call them. Run once.
create or replace function spin_roulette(p_bet numeric, p_kind text, p_num int default null) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Roulette has been removed'; end $$;

create or replace function roulette_recent() returns int[]
language plpgsql security definer set search_path = public as $$
begin return '{}'::int[]; end $$;

notify pgrst, 'reload schema';
