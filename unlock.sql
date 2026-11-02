-- Jambling: undo lockdown.sql (puts back the exact permissions that were saved). Run in Supabase > SQL Editor.
do $$
declare r record;
begin
  for r in select * from _lockdown_acl where kind = 'f' loop
    execute format('update pg_proc set proacl = %L::aclitem[] where oid = %L::regprocedure', nullif(r.acl, ''), r.name);
  end loop;
  for r in select * from _lockdown_acl where kind = 't' loop
    execute format('update pg_class set relacl = %L::aclitem[] where oid = %L::regclass', nullif(r.acl, ''), r.name);
  end loop;
end $$;
drop table _lockdown_acl;
notify pgrst, 'reload schema';
