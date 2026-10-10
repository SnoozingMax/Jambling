-- Jambling: online dots. Run once in Supabase > SQL Editor (safe to run again).
alter table profiles add column if not exists last_seen timestamptz;

-- the site calls this every 30s while it's open
create or replace function heartbeat() returns void
language sql security definer set search_path = public as $$
  update profiles set last_seen = now() where id = auth.uid()
$$;
revoke execute on function heartbeat() from anon;

notify pgrst, 'reload schema';
