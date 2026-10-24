-- Jambling: new "Tester" title (rainbow outlined, animated) + remove Steal/Poison from the shop.
-- Run once in Supabase > SQL Editor.

-- Tester title: a boolean on profiles, granted by max only (like Aurora).
alter table profiles add column if not exists tester boolean not null default false;

create or replace function admin_gift_tester(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not am_owner() then raise exception 'Only max can grant the Tester title'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set tester = p_on where id = them;
  return json_build_object('user', them_name, 'tester', p_on);
end $$;
revoke execute on function admin_gift_tester(text, boolean) from anon;
grant execute on function admin_gift_tester(text, boolean) to authenticated;

-- Remove Steal + Poison from the shop: make the RPCs refuse so no old client can still buy them.
create or replace function shop_steal(p_target text) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Steal has been removed from the shop'; end $$;

create or replace function shop_poison() returns json
language plpgsql security definer set search_path = public as $$
begin raise exception 'Poison has been removed from the shop'; end $$;

create or replace function poison_pulse() returns json
language plpgsql security definer set search_path = public as $$
begin return json_build_object('ok', true); end $$;

notify pgrst, 'reload schema';
