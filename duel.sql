-- Jambling: make 1v1 a prediction/juke duel. Run once in Supabase > SQL Editor (after boxing.sql, or on its own).
-- One player ATTACKS, the other DODGES. Both secretly pick a side (Up/Down/Left/Right) at the same time,
-- resolved only once BOTH are in, so reaction time and lag never matter.
--   Same side  -> the attacker read you: HIT, their streak +1.
--   Different   -> you dodged: it becomes YOUR turn to attack (no point), their streak resets.
-- First to land 3 hits in a row wins. You can't pick the same side twice in a row.

alter table pvp_matches add column if not exists attacker uuid;
alter table pvp_matches add column if not exists streak int not null default 0;
alter table pvp_matches add column if not exists a_last text;
alter table pvp_matches add column if not exists b_last text;

-- pay out and close a finished duel (internal)
create or replace function _pvp_finish(p_id uuid, w uuid, res text) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' then return; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
end $$;

-- kept for the round-cap path
create or replace function _pvp_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or m.round <= 40 then return; end if;
  perform _pvp_finish(p_id, null, 'tie');   -- 40 exchanges with nobody reaching 3 in a row = draw
end $$;

-- resolve one exchange once both picks are in (internal)
create or replace function _box_resolve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; hit boolean; new_atk uuid; new_streak int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or m.a_move is null or m.b_move is null then return; end if;
  hit := m.a_move = m.b_move;                          -- attacker guessed the same side = landed
  if hit then new_atk := m.attacker; new_streak := m.streak + 1;
  else new_atk := case when m.attacker = m.a then m.b else m.a end; new_streak := 0;   -- dodged: turn flips
  end if;
  update pvp_matches set
    log = log || jsonb_build_object('round', m.round, 'am', m.a_move, 'bm', m.b_move,
                   'atk', case when m.attacker = m.a then 'a' else 'b' end, 'hit', hit, 'streak', new_streak),
    attacker = new_atk, streak = new_streak,
    a_last = m.a_move, b_last = m.b_move, a_move = null, b_move = null,
    round = m.round + 1, a_acted = now(), b_acted = now()
   where id = m.id;
  if hit and new_streak >= 3 then perform _pvp_finish(p_id, m.attacker, 'win');
  else perform _pvp_settle(p_id); end if;
end $$;
revoke execute on function _pvp_finish(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function _pvp_settle(uuid) from public, anon, authenticated;
revoke execute on function _box_resolve(uuid) from public, anon, authenticated;

-- housekeeping: expire old challenges; if a player sits 75s, auto-pick a random legal side so matches never hang
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; dirs text[] := array['up','down','left','right']; pick text;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.a_move is null and m.a_acted < now() - interval '75 seconds' then
      select d into pick from unnest(dirs) d where d is distinct from m.a_last order by random() limit 1;
      update pvp_matches set a_move = pick where id = m.id;
    end if;
    if m.b_move is null and m.b_acted < now() - interval '75 seconds' then
      select d into pick from unnest(dirs) d where d is distinct from m.b_last order by random() limit 1;
      update pvp_matches set b_move = pick where id = m.id;
    end if;
    perform _box_resolve(m.id);
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- what one player may see (never the opponent's pick until the exchange resolves)
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me;
begin
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round, 'streak', m.streak,
    'attacking', m.attacker = me,
    'my_move', case when is_a then m.a_move else m.b_move end,
    'my_last', case when is_a then m.a_last else m.b_last end,
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- accept: challenger (a) attacks first
create or replace function pvp_accept(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; bal numeric;
begin
  perform _pvp_tidy();
  select * into m from pvp_matches where id = p_id and b = me for update;
  if not found or m.status <> 'pending' then raise exception 'That challenge is gone'; end if;
  if exists (select 1 from pvp_matches where (a = me or b = me) and status = 'live') then raise exception 'Finish your current match first'; end if;
  if not m.friendly then
    select balance into bal from profiles where id = me for update;
    if bal - m.stake < 1000 then raise exception 'You need % coins above 1,000 to accept', m.stake; end if;
    update profiles set balance = balance - m.stake where id = me;
  end if;
  update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
         a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
   where id = m.id;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- lock in your side for this exchange (can't repeat your own last side)
create or replace function pvp_pick(p_id uuid, p_dir text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; mylast text;
begin
  if p_dir not in ('up','down','left','right') then raise exception 'Bad move'; end if;
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' then raise exception 'No match in play'; end if;
  is_a := m.a = me;
  if (is_a and m.a_move is not null) or (not is_a and m.b_move is not null) then
    raise exception 'You already picked. Waiting on your opponent.';
  end if;
  mylast := case when is_a then m.a_last else m.b_last end;
  if p_dir = mylast then raise exception 'You can''t pick the same side twice in a row'; end if;
  if is_a then update pvp_matches set a_move = p_dir, a_acted = now() where id = m.id;
  else update pvp_matches set b_move = p_dir, b_acted = now() where id = m.id; end if;
  perform _box_resolve(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- old move functions are gone
create or replace function pvp_box(p_id uuid, p_move text) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception '1v1 was updated. Refresh the page.'; end $$;
create or replace function pvp_move(p_id uuid, p_hit boolean) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception '1v1 was updated. Refresh the page.'; end $$;

notify pgrst, 'reload schema';
