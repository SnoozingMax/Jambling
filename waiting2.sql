-- Jambling: Reject hides someone from the waiting room instead of deleting them.
-- They can tap "Ask again" to get back on the list (bots won't). Run once in Supabase > SQL Editor.

alter table profiles add column if not exists rejected_at timestamptz;

create or replace function admin_pending() returns table(username text, joined timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query select p.username, p.created_at from profiles p
    where not p.approved and not p.banned and p.rejected_at is null order by p.created_at;
end $$;

create or replace function admin_approve(p_user text, p_ok boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_ok then update profiles set approved = true, rejected_at = null where id = them;
  else update profiles set rejected_at = now() where id = them;
  end if;
  return json_build_object('user', them_name, 'ok', p_ok);
end $$;

-- player: get back on the waiting list after being turned down (once every 10 minutes)
create or replace function ask_again() returns json
language plpgsql security definer set search_path = public as $$
declare r timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select rejected_at into r from profiles where id = auth.uid();
  if r is null then return json_build_object('ok', true); end if;
  if r > now() - interval '10 minutes' then
    raise exception 'You can ask again in % min', ceil(extract(epoch from (r + interval '10 minutes' - now())) / 60);
  end if;
  update profiles set rejected_at = null where id = auth.uid();
  return json_build_object('ok', true);
end $$;

notify pgrst, 'reload schema';
