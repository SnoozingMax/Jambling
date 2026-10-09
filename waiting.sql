-- Jambling: waiting room. New accounts can't play until an admin accepts them.
-- Everyone who already has an account is accepted automatically.
-- Run once in Supabase > SQL Editor (safe to run again).

alter table profiles add column if not exists approved boolean not null default true;   -- existing accounts: in
alter table profiles alter column approved set default false;                            -- new accounts: waiting

-- waiting players' coins are frozen: no bets, daily, refill, gifts in or out
create or replace function _waiting_frozen() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not new.approved and new.balance is distinct from old.balance and not is_admin() then
    raise exception 'Your account is waiting to be accepted by an admin';
  end if;
  return new;
end $$;
drop trigger if exists waiting_frozen on profiles;
create trigger waiting_frozen before update on profiles
for each row execute function _waiting_frozen();

-- no 1v1s (even friendly) with someone still waiting
create or replace function _pvp_needs_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from profiles where id in (new.a, new.b) and not approved) then
    raise exception 'That player is still waiting to be accepted';
  end if;
  return new;
end $$;
drop trigger if exists pvp_needs_approved on pvp_matches;
create trigger pvp_needs_approved before insert on pvp_matches
for each row execute function _pvp_needs_approved();

-- admin: who's waiting
create or replace function admin_pending() returns table(username text, joined timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select p.username, p.created_at from profiles p
    where not p.approved and not p.banned order by p.created_at;
end $$;

-- admin: accept (p_ok = true) or reject = delete the account (p_ok = false)
create or replace function admin_approve(p_user text, p_ok boolean) returns json
language plpgsql security definer set search_path = public, auth as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_ok then update profiles set approved = true where id = them;
  else
    if exists (select 1 from admins where user_id = them) then raise exception 'Can''t delete an admin'; end if;
    delete from auth.users where id = them;
  end if;
  return json_build_object('user', them_name, 'ok', p_ok);
end $$;
revoke execute on function admin_pending() from anon;
revoke execute on function admin_approve(text, boolean) from anon;

notify pgrst, 'reload schema';
