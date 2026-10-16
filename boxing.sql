-- Jambling: turn 1v1 into Shadow Boxing. Run once in Supabase > SQL Editor.
-- Both players secretly pick a move each round; the server only resolves once BOTH are in,
-- so reaction time and lag never matter (no unfair advantage). First to drop the other to 0 HP wins.
--
-- Moves (damage you deal, by your move vs theirs):
--   JAB   fast poke   vs JAB 6,  vs HOOK 14, vs BLOCK 0,  vs DODGE 10   (interrupts hooks, tracks dodges)
--   HOOK  heavy swing vs JAB 0,  vs HOOK 18, vs BLOCK 16, vs DODGE 0    (smashes guards, whiffs vs jab/dodge)
--   BLOCK guard       deals 0, but fully stops a JAB (take 0)           (loses to HOOK)
--   DODGE slip        deals 0, except a 12 COUNTER when they HOOK        (loses to JAB)
-- Rock-paper-scissors: BLOCK beats JAB, HOOK beats BLOCK, JAB/DODGE beat HOOK, JAB beats DODGE.

alter table pvp_matches add column if not exists a_hp int not null default 100;
alter table pvp_matches add column if not exists b_hp int not null default 100;
alter table pvp_matches add column if not exists a_move text;
alter table pvp_matches add column if not exists b_move text;
alter table pvp_matches add column if not exists round int not null default 1;
alter table pvp_matches add column if not exists log jsonb not null default '[]';

-- any boxing match still stuck on the old blackjack code: void it so nobody is frozen
update pvp_matches set status = 'done', result = 'tie', winner = null
 where status = 'live' and a_hp = 100 and b_hp = 100 and (a_cards <> '{}' or b_cards <> '{}') and round = 1 and a_move is null and b_move is null;

create or replace function _box_dmg(mine text, theirs text) returns int
language sql immutable as $$
  select case mine
    when 'jab'   then case theirs when 'jab' then 6  when 'hook' then 14 when 'block' then 0  when 'dodge' then 10 else 0 end
    when 'hook'  then case theirs when 'jab' then 0  when 'hook' then 18 when 'block' then 16 when 'dodge' then 0  else 0 end
    when 'dodge' then case theirs when 'hook' then 12 else 0 end
    else 0 end
$$;

-- decide a finished boxing match by HP and pay out (internal)
create or replace function _pvp_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; w uuid; res text;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' then return; end if;
  -- fight ends on a KO or at the round cap (25)
  if m.a_hp > 0 and m.b_hp > 0 and m.round <= 25 then return; end if;
  if m.a_hp = m.b_hp then w := null; res := 'tie';
  elsif m.a_hp > m.b_hp then w := m.a; res := 'win';
  else w := m.b; res := 'win'; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
end $$;

-- once both moves are in for the round, resolve it (internal)
create or replace function _box_resolve(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; da int; db int; na int; nb int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or m.a_move is null or m.b_move is null then return; end if;
  db := _box_dmg(m.a_move, m.b_move);   -- damage a deals to b
  da := _box_dmg(m.b_move, m.a_move);   -- damage b deals to a
  na := greatest(0, m.a_hp - da);
  nb := greatest(0, m.b_hp - db);
  update pvp_matches set
    a_hp = na, b_hp = nb,
    log = log || jsonb_build_object('round', m.round, 'am', m.a_move, 'bm', m.b_move, 'ad', db, 'bd', da, 'ahp', na, 'bhp', nb),
    round = m.round + 1, a_move = null, b_move = null, a_acted = now(), b_acted = now()
   where id = m.id;
  perform _pvp_settle(m.id);
end $$;
revoke execute on function _box_dmg(text, text) from public, anon, authenticated;
revoke execute on function _box_resolve(uuid) from public, anon, authenticated;
revoke execute on function _pvp_settle(uuid) from public, anon, authenticated;

-- housekeeping: expire old challenges; if a player sits on a move for 75s, auto-BLOCK so matches never hang
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.a_move is null and m.a_acted < now() - interval '75 seconds' then update pvp_matches set a_move = 'block' where id = m.id; end if;
    if m.b_move is null and m.b_acted < now() - interval '75 seconds' then update pvp_matches set b_move = 'block' where id = m.id; end if;
    perform _box_resolve(m.id);
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

-- what one player is allowed to see (never the opponent's move until the round resolves)
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me;
begin
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round,
    'my_hp', case when is_a then m.a_hp else m.b_hp end,
    'opp_hp', case when is_a then m.b_hp else m.a_hp end,
    'my_move', case when is_a then m.a_move else m.b_move end,          -- what I locked in (null = not yet)
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- accept a challenge: start the fight at 100 HP each
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
  update pvp_matches set status = 'live', a_hp = 100, b_hp = 100, round = 1,
         a_move = null, b_move = null, log = '[]', a_acted = now(), b_acted = now()
   where id = m.id;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- lock in your move for the current round
create or replace function pvp_box(p_id uuid, p_move text) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean;
begin
  if p_move not in ('jab','hook','block','dodge') then raise exception 'Bad move'; end if;
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' then raise exception 'No match in play'; end if;
  is_a := m.a = me;
  if (is_a and m.a_move is not null) or (not is_a and m.b_move is not null) then
    raise exception 'You already moved. Waiting on your opponent.';
  end if;
  if is_a then update pvp_matches set a_move = p_move, a_acted = now() where id = m.id;
  else update pvp_matches set b_move = p_move, b_acted = now() where id = m.id; end if;
  perform _box_resolve(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- old blackjack move function is gone
create or replace function pvp_move(p_id uuid, p_hit boolean) returns json
language plpgsql security definer set search_path = public as $$
begin raise exception '1v1 is now Shadow Boxing. Refresh the page.'; end $$;

notify pgrst, 'reload schema';
