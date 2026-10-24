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
