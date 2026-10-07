-- Jambling: site notice + players can change their own name. Run once in Supabase > SQL Editor (safe to run again).

create table if not exists site_notice (id int primary key default 1 check (id = 1), text text not null default '');
alter table site_notice enable row level security;
drop policy if exists "notice readable" on site_notice;
create policy "notice readable" on site_notice for select to anon, authenticated using (true);
insert into site_notice (id, text)
values (1, 'Change your username to your real name by Tuesday, Oct 13, or your account will be banned.')
on conflict (id) do update set text = excluded.text;

create or replace function admin_set_notice(p_text text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update site_notice set text = coalesce(trim(p_text), '') where id = 1;
  return json_build_object('text', coalesce(trim(p_text), ''));
end $$;

-- change your own name (your login name changes too)
create or replace function rename_me(p_new text) returns json
language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); old_name text; new_email text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  p_new := trim(p_new);
  if p_new !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'Name: 3-20 letters, numbers, or _'; end if;
  select username into old_name from profiles where id = me;
  if exists (select 1 from profiles where lower(username) = lower(p_new) and id <> me) then raise exception 'That name is taken'; end if;
  new_email := lower(p_new) || '@users.jambling.app';
  if (select email from auth.users where id = me) like '%@users.jambling.app' then
    if exists (select 1 from auth.users where email = new_email and id <> me) then raise exception 'That name is taken'; end if;
    update auth.users set email = new_email where id = me;
    update auth.identities set identity_data = identity_data || jsonb_build_object('email', new_email)
      where user_id = me and provider = 'email';
  end if;
  update profiles set username = p_new where id = me;
  return json_build_object('old', old_name, 'new', p_new);
end $$;

notify pgrst, 'reload schema';
