-- Jambling: mods can grant coins: 2 grants a day, 1,000,000 total a day (resets midnight Pacific).
-- Run once in Supabase > SQL Editor (safe to run again).

create table if not exists mod_grants (by_user uuid not null, target uuid not null, amount numeric not null, at timestamptz not null default now());
alter table mod_grants enable row level security;   -- no policies: only functions touch it

create or replace function mod_grants_left() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'grants', greatest(0, 2 - count(*)),
    'coins', greatest(0, 1000000 - coalesce(sum(amount), 0)))
  from mod_grants
  where by_user = auth.uid()
    and (at at time zone 'America/Los_Angeles')::date = (now() at time zone 'America/Los_Angeles')::date
$$;

create or replace function mod_give(p_user text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; lft json; bal numeric;
begin
  if my_role() is distinct from 'mod' then raise exception 'Moderators only (admins use Gift coins in the admin panel)'; end if;
  p_amount := round(coalesce(p_amount, 0), 2);
  if p_amount <= 0 or p_amount <> p_amount then raise exception 'Enter an amount'; end if;
  select id, username into them, them_name from profiles
   where lower(username) = lower(trim(p_user)) and not banned and approved order by created_at limit 1;
  if them is null then raise exception 'No player named % (or they''re banned / still waiting)', p_user; end if;
  if them = auth.uid() then raise exception 'You can''t grant coins to yourself'; end if;
  perform pg_advisory_xact_lock(hashtext('mod_give' || auth.uid()::text));   -- no double-spending with two taps at once
  lft := mod_grants_left();
  if (lft->>'grants')::int <= 0 then raise exception 'You''ve used both grants for today'; end if;
  if p_amount > (lft->>'coins')::numeric then raise exception 'You can only grant % more today', to_char((lft->>'coins')::numeric, 'FM9,999,999'); end if;
  update profiles set balance = balance + p_amount where id = them returning balance into bal;
  insert into mod_grants (by_user, target, amount) values (auth.uid(), them, p_amount);
  return json_build_object('user', them_name, 'gave', p_amount, 'left', mod_grants_left());
end $$;
revoke execute on function mod_give(text, numeric) from anon;

notify pgrst, 'reload schema';
