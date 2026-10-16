-- Jambling: add Filler as a second 1v1 mode. Run once in Supabase > SQL Editor (after duel.sql).
-- Filler: 7x6 board of 6 colors. You own bottom-left, opponent owns top-right. Take turns picking a
-- color (not your current or your opponent's current); your blob becomes that color and absorbs any
-- touching tiles of it. When the board fills, most tiles wins. Turn-based, pure strategy, no luck.

alter table pvp_matches add column if not exists game text not null default 'duel';
alter table pvp_matches add column if not exists fb int[];     -- board colors, row-major, length 42
alter table pvp_matches add column if not exists fo int[];     -- owner per tile: 0 neutral, 1 = player a, 2 = player b
alter table pvp_matches add column if not exists fturn uuid;   -- whose move

-- flood: set player p's blob to color k, then absorb neutral touching tiles of color k (7 rows x 6 cols)
create or replace function _filler_apply(board int[], own int[], p int, k int, out ob int[], out oo int[])
language plpgsql immutable as $$
declare cols int := 6; rows int := 7; i int; rr int; cc int; changed boolean; n int;
begin
  ob := board; oo := own;
  for i in 1..42 loop if oo[i] = p then ob[i] := k; end if; end loop;
  loop
    changed := false;
    for i in 1..42 loop
      if oo[i] = 0 and ob[i] = k then
        rr := (i - 1) / cols; cc := (i - 1) % cols;
        foreach n in array array[
          case when rr > 0 then i - cols end, case when rr < rows-1 then i + cols end,
          case when cc > 0 then i - 1 end, case when cc < cols-1 then i + 1 end] loop
          if n is not null and oo[n] = p then oo[i] := p; changed := true; exit; end if;
        end loop;
      end if;
    end loop;
    exit when not changed;
  end loop;
end $$;

create or replace function _filler_color(board int[], own int[], p int) returns int
language sql immutable as $$ select (select board[i] from generate_series(1,42) i where own[i] = p limit 1) $$;

create or replace function _filler_count(own int[], p int) returns int
language sql immutable as $$ select count(*)::int from generate_series(1,42) i where own[i] = p $$;

-- start a filler board: random colors, corners must differ
create or replace function _filler_start() returns int[]
language plpgsql volatile as $$
declare b int[];
begin
  loop
    select array_agg(floor(random()*6)::int) into b from generate_series(1,42);
    exit when b[37] <> b[6];   -- bottom-left (index 37) vs top-right (index 6)
  end loop;
  return b;
end $$;
revoke execute on function _filler_apply(int[],int[],int,int) from public, anon, authenticated;
revoke execute on function _filler_color(int[],int[],int) from public, anon, authenticated;
revoke execute on function _filler_count(int[],int) from public, anon, authenticated;
revoke execute on function _filler_start() from public, anon, authenticated;

create or replace function pvp_fill(p_id uuid, p_color int) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; p int; nbd int[]; nown int[]; na int; nb int; w uuid; r text;
begin
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' or m.game <> 'filler' then raise exception 'No match in play'; end if;
  if m.fturn <> me then raise exception 'Not your turn'; end if;
  if p_color < 0 or p_color > 5 then raise exception 'Bad color'; end if;
  p := case when m.a = me then 1 else 2 end;
  if p_color = _filler_color(m.fb, m.fo, 1) or p_color = _filler_color(m.fb, m.fo, 2) then
    raise exception 'That color is in play';
  end if;
  select ob, oo into nbd, nown from _filler_apply(m.fb, m.fo, p, p_color);
  na := _filler_count(nown, 1); nb := _filler_count(nown, 2);
  if na + nb >= 42 then
    if na = nb then w := null; r := 'tie'; elsif na > nb then w := m.a; r := 'win'; else w := m.b; r := 'win'; end if;
    if not m.friendly then
      if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
      else update profiles set balance = balance + m.stake * 2 where id = w; end if;
    end if;
    update pvp_matches set fb = nbd, fo = nown, status = 'done', winner = w, result = r where id = m.id;
  else
    update pvp_matches set fb = nbd, fo = nown, fturn = case when m.a = me then m.b else m.a end,
           a_acted = now(), b_acted = now() where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

notify pgrst, 'reload schema';

-- challenge now carries a game type
create or replace function pvp_challenge(p_user text, p_stake numeric, p_friendly boolean, p_game text default 'duel') returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); them uuid; bal numeric; m pvp_matches;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_game not in ('duel','filler') then p_game := 'duel'; end if;
  perform _pvp_tidy();
  select id into them from profiles where lower(username) = lower(trim(p_user)) and not banned order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if them = me then raise exception 'You can''t challenge yourself'; end if;
  if exists (select 1 from pvp_matches where (a = me or b = me) and status = 'live') then raise exception 'Finish your current match first'; end if;
  if exists (select 1 from pvp_matches where a = me and status = 'pending') then raise exception 'You already have a challenge waiting. Cancel it first.'; end if;
  if p_friendly then p_stake := 0;
  else
    p_stake := round(p_stake, 2);
    if p_stake is null or p_stake <= 0 then raise exception 'Enter a stake'; end if;
    select balance into bal from profiles where id = me for update;
    if bal - p_stake < 1000 then raise exception 'You can only stake coins above 1,000 (you can stake %)', greatest(0, bal - 1000); end if;
    update profiles set balance = balance - p_stake where id = me;
  end if;
  insert into pvp_matches (a, b, stake, friendly, game) values (me, them, p_stake, p_friendly, p_game) returning * into m;
  return _pvp_view(m, me);
end $$;

-- accept: branch on game
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
  if m.game = 'filler' then
    declare brd int[] := _filler_start(); own0 int[];
    begin
      select array_agg(case when i = 37 then 1 when i = 6 then 2 else 0 end) into own0 from generate_series(1,42) i;
      update pvp_matches set status = 'live', fb = brd, fo = own0, fturn = m.a, a_acted = now(), b_acted = now() where id = m.id;
    end;
  else
    update pvp_matches set status = 'live', attacker = m.a, streak = 0, round = 1,
           a_move = null, b_move = null, a_last = null, b_last = null, log = '[]', a_acted = now(), b_acted = now()
     where id = m.id;
  end if;
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- view: duel fields OR filler fields depending on game
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare is_a boolean := m.a = me; p int := case when m.a = me then 1 else 2 end;
begin
  if m.game = 'filler' then
    return json_build_object(
      'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'filler', 'challenger', is_a,
      'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
      'board', m.fb, 'owner', m.fo, 'me_p', p,
      'my_turn', m.fturn = me,
      'my_color', _filler_color(m.fb, m.fo, p), 'opp_color', _filler_color(m.fb, m.fo, 3 - p),
      'my_count', _filler_count(m.fo, p), 'opp_count', _filler_count(m.fo, 3 - p),
      'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
      'balance', (select balance from profiles where id = me));
  end if;
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'game', 'duel', 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'round', m.round, 'streak', m.streak, 'attacking', m.attacker = me,
    'my_move', case when is_a then m.a_move else m.b_move end,
    'my_last', case when is_a then m.a_last else m.b_last end,
    'opp_locked', case when is_a then m.b_move is not null else m.a_move is not null end,
    'log', m.log,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

-- housekeeping: expire old challenges; auto-move idle players in both games (90s)
create or replace function _pvp_tidy() returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; dirs text[] := array['up','down','left','right']; pick text; k int; idle uuid;
begin
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'pending'
             and created_at < now() - interval '5 minutes' for update loop
    if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
    update pvp_matches set status = 'expired' where id = m.id;
  end loop;
  for m in select * from pvp_matches where (a = auth.uid() or b = auth.uid()) and status = 'live' for update loop
    if m.game = 'filler' then
      idle := case when m.fturn = m.a and m.a_acted < now() - interval '90 seconds' then m.a
                   when m.fturn = m.b and m.b_acted < now() - interval '90 seconds' then m.b end;
      if idle is not null then
        select c into k from generate_series(0,5) c
          where c <> _filler_color(m.fb, m.fo, 1) and c <> _filler_color(m.fb, m.fo, 2) order by random() limit 1;
        declare nbd int[]; nown int[]; na int; nb int; w uuid; r text;
        begin
          select ob, oo into nbd, nown from _filler_apply(m.fb, m.fo, case when idle = m.a then 1 else 2 end, k);
          na := _filler_count(nown,1); nb := _filler_count(nown,2);
          if na + nb >= 42 then
            if na = nb then w := null; r := 'tie'; elsif na > nb then w := m.a; r := 'win'; else w := m.b; r := 'win'; end if;
            if not m.friendly then
              if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
              else update profiles set balance = balance + m.stake * 2 where id = w; end if;
            end if;
            update pvp_matches set fb = nbd, fo = nown, status='done', winner=w, result=r where id = m.id;
          else
            update pvp_matches set fb = nbd, fo = nown, fturn = case when idle = m.a then m.b else m.a end,
                   a_acted = now(), b_acted = now() where id = m.id;
          end if;
        end;
      end if;
    else
      if m.a_move is null and m.a_acted < now() - interval '75 seconds' then
        select d into pick from unnest(dirs) d where d is distinct from m.a_last order by random() limit 1;
        update pvp_matches set a_move = pick where id = m.id;
      end if;
      if m.b_move is null and m.b_acted < now() - interval '75 seconds' then
        select d into pick from unnest(dirs) d where d is distinct from m.b_last order by random() limit 1;
        update pvp_matches set b_move = pick where id = m.id;
      end if;
      perform _box_resolve(m.id);
    end if;
  end loop;
end $$;
revoke execute on function _pvp_tidy() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- pvp_state: include the game type in the challenge lists
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly, 'game', m.game)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

notify pgrst, 'reload schema';
