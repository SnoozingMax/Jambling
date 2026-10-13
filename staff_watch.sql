-- Jambling: only max can do Rush hour + Boost, and max can see everything other admins/mods do.
-- Run once in Supabase > SQL Editor (safe to run again).

-- ---------- Rush hour + Boost: owner only ----------
create or replace function _owner_only_rush() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.rush_until is distinct from old.rush_until and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can start or end rush hour';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_rush on site_state;
create trigger owner_only_rush before update on site_state
for each row execute function _owner_only_rush();

create or replace function _owner_only_boost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.boost_until is not null and new.boost_until is distinct from old.boost_until
     and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can boost';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_boost on profiles;
create trigger owner_only_boost before update on profiles
for each row execute function _owner_only_boost();

-- ---------- Staff activity log ----------
create table if not exists staff_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid, actor_name text, target_name text, what text not null
);
alter table staff_log enable row level security;   -- no policies: only functions touch it

create or replace function _is_staff_not_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and not am_owner()
     and (exists (select 1 from admins where user_id = auth.uid()) or exists (select 1 from moderators where user_id = auth.uid()))
$$;

create or replace function _log_staff(p_target text, p_what text) returns void
language sql security definer set search_path = public as $$
  insert into staff_log (actor, actor_name, target_name, what)
  values (auth.uid(), (select username from profiles where id = auth.uid()), p_target, p_what)
$$;

-- anything a non-owner admin/mod does to someone else's account gets written down
create or replace function _watch_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
declare w text[] := '{}';
begin
  if not _is_staff_not_owner() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.id <> auth.uid() then perform _log_staff(old.username, 'deleted the account (had ' || to_char(old.balance, 'FM999,999,999,999,990') || ' coins)'); end if;
    return old;
  end if;
  if new.id = auth.uid() then return new; end if;   -- their own playing isn't logged
  if new.balance > old.balance then w := w || ('gave ' || to_char(new.balance - old.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.balance < old.balance then w := w || ('took ' || to_char(old.balance - new.balance, 'FM999,999,999,999,990.00') || ' coins'); end if;
  if new.username is distinct from old.username then w := w || ('renamed ' || old.username || ' → ' || new.username); end if;
  if new.rebirths is distinct from old.rebirths then w := w || ('rebirths ' || old.rebirths || ' → ' || new.rebirths); end if;
  if new.badluck_until is distinct from old.badluck_until then
    w := w || (case when new.badluck_until is null or new.badluck_until < now() then 'removed bad luck' else 'gave bad luck' end);
  end if;
  if new.boost_until is distinct from old.boost_until and new.boost_until is null then w := w || 'removed boost'::text; end if;
  if new.approved is distinct from old.approved then w := w || (case when new.approved then 'accepted from waiting room' else 'sent to waiting room' end); end if;
  if new.rejected_at is distinct from old.rejected_at and new.rejected_at is not null then w := w || 'rejected from waiting room'::text; end if;
  if array_length(w, 1) > 0 then perform _log_staff(new.username, array_to_string(w, ', ')); end if;
  return new;
end $$;
drop trigger if exists watch_profiles on profiles;
create trigger watch_profiles after update or delete on profiles
for each row execute function _watch_profiles();

create or replace function _watch_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _is_staff_not_owner() and new.text is distinct from old.text then
    perform _log_staff(null, case when coalesce(new.text, '') = '' then 'hid the site notice' else 'set site notice: "' || new.text || '"' end);
  end if;
  return new;
end $$;
drop trigger if exists watch_notice on site_notice;
create trigger watch_notice after update on site_notice
for each row execute function _watch_notice();

-- max only: read the log
create or replace function staff_activity(p_limit int default 200) returns table(at timestamptz, who text, target text, what text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not am_owner() then raise exception 'Only max can see staff activity'; end if;
  return query select l.at, l.actor_name, l.target_name, l.what from staff_log l order by l.id desc limit least(coalesce(p_limit, 200), 1000);
end $$;
revoke execute on function staff_activity(int) from anon;

notify pgrst, 'reload schema';
