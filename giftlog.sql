-- Jambling: admin gift log. Run once in Supabase > SQL Editor (safe to run again).
-- Last 200 gifts, or only ones involving a player if you type a name.
create or replace function admin_gift_log(p_user text default null) returns table(at timestamptz, from_user text, to_user text, amount numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return query
    select g.created_at, f.username, t.username, g.amount
    from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
    where coalesce(trim(p_user), '') = ''
       or lower(f.username) = lower(trim(p_user)) or lower(t.username) = lower(trim(p_user))
    order by g.created_at desc
    limit 200;
end $$;
revoke execute on function admin_gift_log(text) from anon;

notify pgrst, 'reload schema';
