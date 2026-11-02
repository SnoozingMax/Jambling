-- Jambling EMERGENCY LOCKDOWN. Run in Supabase > SQL Editor.
-- Stops every player (even ones with the page still open) from calling any game function or touching any table.
-- Saves the current permissions first so unlock.sql puts everything back exactly as it was.
create table if not exists _lockdown_acl (kind text, name text, acl text, primary key (kind, name));
insert into _lockdown_acl (kind, name, acl)
  select 'f', p.oid::regprocedure::text, coalesce(p.proacl::text, '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
  on conflict do nothing;
insert into _lockdown_acl (kind, name, acl)
  select 't', c.oid::regclass::text, coalesce(c.relacl::text, '') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'v')
  on conflict do nothing;
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.f);
  end loop;
  for r in select c.oid::regclass as t from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'v') and c.relname <> '_lockdown_acl' loop
    execute format('revoke all on %s from anon, authenticated', r.t);
  end loop;
end $$;
notify pgrst, 'reload schema';
