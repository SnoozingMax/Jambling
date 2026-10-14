-- Jambling: only max can change the site notice. Run once in Supabase > SQL Editor (after staff_all.sql).
create or replace function _owner_only_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.text is distinct from old.text and auth.uid() is not null and not am_owner() then
    raise exception 'Only max can change the site notice';
  end if;
  return new;
end $$;
drop trigger if exists owner_only_notice on site_notice;
create trigger owner_only_notice before update on site_notice
for each row execute function _owner_only_notice();
