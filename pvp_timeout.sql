-- Jambling: 1v1 - if you don't move within 15s you lose (forfeit). Run once in Supabase > SQL Editor.

create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; idle uuid;
begin
  -- expire stale challenges (5 min)
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  -- live matches: forfeit a player who hasn't moved in 15 seconds
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.game = 'filler' then
      idle := case when m.fturn = m.a and m.a_acted < now() - interval '15 seconds' then m.a
                   when m.fturn = m.b and m.b_acted < now() - interval '15 seconds' then m.b end;
      if idle is not null then
        perform _pvp_finish(m.id, case when idle = m.a then m.b else m.a end, 'win');   -- idle = you lose
      end if;
    else
      if m.a_move is null and m.a_acted < now() - interval '15 seconds'
         and m.b_move is null and m.b_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, null, 'tie');          -- both idle: draw
      elsif m.a_move is null and m.a_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, m.b, 'win');           -- a idle: a loses
      elsif m.b_move is null and m.b_acted < now() - interval '15 seconds' then
        perform _pvp_finish(m.id, m.a, 'win');           -- b idle: b loses
      else
        perform _box_resolve(m.id);                      -- both moved: resolve the exchange
      end if;
    end if;
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- view: add secs_left (how long until the current player forfeits)
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end; sl numeric;
begin
  if m.game = 'filler' then
    sl := case when m.status = 'live' and m.fturn = me
               then greatest(0, 15 - extract(epoch from now() - case when is_a then m.a_acted else m.b_acted end)) end;
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'filler', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'board', m.fb, 'owner', m.fo, 'me_p', p,
      'my_turn', m.fturn = me, 'secs_left', sl,
      'my_color', _filler_color(m.fb, m.fo, p), 'opp_color', _filler_color(m.fb, m.fo, 3 - p),
      'my_count', _filler_count(m.fo, p), 'opp_count', _filler_count(m.fo, 3 - p),
      'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
      'balance', (select balance from profiles where id = me));
  end if;
  sl := case when m.status = 'live' and (case when is_a then m.a_move else m.b_move end) is null
             then greatest(0, 15 - extract(epoch from now() - case when is_a then m.a_acted else m.b_acted end)) end;
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'duel', 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round, 'streak', m.streak, 'attacking', m.attacker = me,
    'my_move', case when is_a then m.a_move else m.b_move end,
    'my_last', case when is_a then m.a_last else m.b_last end,
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'secs_left', sl, 'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
