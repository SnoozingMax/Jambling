-- Jambling: equip / unequip the 200 HP upgrade. Run once in Supabase > SQL Editor (after archer_upgrades.sql).
-- Owning it doesn't force it on any more: it only applies while equipped (on by default).
alter table archer_owned add column if not exists equipped boolean not null default true;

create or replace function _archer_maxhp(p_uid uuid) returns int language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from archer_owned where user_id = p_uid and kind = 'hp200' and equipped) then 200 else 100 end
$$;
revoke execute on function _archer_maxhp(uuid) from public, anon, authenticated;

create or replace function archer_arrows() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('owned', _archer_owned(auth.uid()), 'max_hp', _archer_maxhp(auth.uid()),
                           'equipped', coalesce((select json_agg(kind) from archer_owned where user_id = auth.uid() and equipped), '[]'::json),
                           'prices', json_build_object('poison', _archer_price('poison'), 'homing', _archer_price('homing'),
                                                       'sniper', _archer_price('sniper'), 'vampire', _archer_price('vampire'), 'hp200', _archer_price('hp200')))
$$;

create or replace function archer_equip(p_kind text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update archer_owned set equipped = coalesce(p_on, true) where user_id = auth.uid() and kind = p_kind;
  if not found then raise exception 'You don''t own that'; end if;
  return archer_arrows();
end $$;
revoke execute on function archer_equip(text, boolean) from anon;

notify pgrst, 'reload schema';
