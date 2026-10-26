-- Jambling: Archers damage now scales with pull strength (body 10-35, headshots 1.6x up to 56). Run once.
create or replace function archer_damage(p_id uuid, p_dmg int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; last_hit timestamptz; hp int;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_dmg is null or p_dmg < 1 or p_dmg > 56 then raise exception 'Bad damage'; end if;   -- body 10-35, headshot up to 56
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'archer' then
    select * into m from pvp_matches where id = p_id;
    return _pvp_view(m, me);
  end if;
  is_a := m.a = me;
  last_hit := case when is_a then m.a_hit_at else m.b_hit_at end;
  if last_hit is not null and clock_timestamp() - last_hit < interval '250 milliseconds' then   -- one arrow can't count twice
    return _pvp_view(m, me);
  end if;
  hp := greatest(0, (case when is_a then m.a_hp else m.b_hp end) - p_dmg);
  if is_a then
    update pvp_matches set a_hp = hp, a_hit_at = clock_timestamp(), a_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'a', 'dmg', p_dmg, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  else
    update pvp_matches set b_hp = hp, b_hit_at = clock_timestamp(), b_acted = now(), round = round + 1,
           log = log || jsonb_build_object('to', 'b', 'dmg', p_dmg, 'at', extract(epoch from clock_timestamp() - rt_start)) where id = m.id;
  end if;
  if hp <= 0 then perform _pvp_finish(m.id, case when is_a then m.b else m.a end, 'win'); end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;
revoke execute on function archer_damage(uuid, int) from anon;

notify pgrst, 'reload schema';
