-- Jambling: 1v1 Blackjack. Run once in Supabase > SQL Editor (safe to run again). Run blackjack.sql first.
-- Both players play their own hand at the same time; closer to 21 without busting wins.
-- Money matches: both stakes are held by the server and the winner takes both.

create table if not exists pvp_matches (
  id uuid primary key default gen_random_uuid(),
  a uuid not null references profiles(id) on delete cascade,   -- challenger
  b uuid not null references profiles(id) on delete cascade,   -- opponent
  stake numeric not null default 0,
  friendly boolean not null,
  status text not null default 'pending',   -- pending | live | done | declined | cancelled | expired
  deck int[], a_cards int[] not null default '{}', b_cards int[] not null default '{}',
  a_done boolean not null default false, b_done boolean not null default false,
  winner uuid, result text,
  created_at timestamptz not null default now(),
  a_acted timestamptz not null default now(), b_acted timestamptz not null default now()
);
alter table pvp_matches enable row level security;   -- no policies: only functions touch it

-- settle a live match once both players are done (internal)
create or replace function _pvp_settle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; ta int; tb int; w uuid; res text;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' or not (m.a_done and m.b_done) then return; end if;
  ta := _bj_total(m.a_cards); tb := _bj_total(m.b_cards);
  if (ta > 21 and tb > 21) or (ta = tb) then w := null; res := 'tie';
  elsif ta > 21 then w := m.b; elsif tb > 21 then w := m.a;
  elsif ta > tb then w := m.a; else w := m.b; end if;
  if w is not null then res := 'win'; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
end $$;

-- housekeeping for my matches: expire old challenges, auto-stand idle players (internal)
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
    if not m.a_done and m.a_acted < now() - interval '90 seconds' then update pvp_matches set a_done = true where id = m.id; end if;
    if not m.b_done and m.b_acted < now() - interval '90 seconds' then update pvp_matches set b_done = true where id = m.id; end if;
    perform _pvp_settle(m.id);
  end loop;
end $$;

-- what one player is allowed to see
create or replace function _pvp_view(m pvp_matches, me uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  is_a boolean := m.a = me;
  mine int[] := case when m.a = me then m.a_cards else m.b_cards end;
  theirs int[] := case when m.a = me then m.b_cards else m.a_cards end;
  shown int[];
begin
  shown := case when m.status = 'done' then theirs else theirs[1:1] end;
  return json_build_object(
    'id', m.id, 'status', m.status, 'friendly', m.friendly, 'stake', m.stake, 'challenger', is_a,
    'opp', (select username from profiles where id = case when is_a then m.b else m.a end),
    'my_cards', mine, 'my_total', _bj_total(mine), 'my_done', case when is_a then m.a_done else m.b_done end,
    'opp_cards', shown, 'opp_count', cardinality(theirs), 'opp_total', _bj_total(shown),
    'opp_done', case when is_a then m.b_done else m.a_done end,
    'outcome', case when m.status <> 'done' then null when m.winner is null then 'tie' when m.winner = me then 'win' else 'lose' end,
    'balance', (select balance from profiles where id = me));
end $$;
revoke execute on function _pvp_settle(uuid) from public, anon, authenticated;
revoke execute on function _pvp_tidy() from public, anon, authenticated;
revoke execute on function _pvp_view(pvp_matches, uuid) from public, anon, authenticated;

create or replace function pvp_challenge(p_user text, p_stake numeric, p_friendly boolean) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); them uuid; bal numeric; m pvp_matches;
begin
  if me is null then raise exception 'Not signed in'; end if;
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
  insert into pvp_matches (a, b, stake, friendly) values (me, them, p_stake, p_friendly) returning * into m;
  return _pvp_view(m, me);
end $$;

create or replace function pvp_accept(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; bal numeric; d int[];
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
  select array_agg(c order by random()) into d from generate_series(0, 51) c;
  update pvp_matches set status = 'live', deck = d[5:], a_cards = array[d[1], d[3]], b_cards = array[d[2], d[4]],
         a_done = _bj_total(array[d[1], d[3]]) = 21, b_done = _bj_total(array[d[2], d[4]]) = 21,
         a_acted = now(), b_acted = now()
   where id = m.id;
  perform _pvp_settle(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

create or replace function pvp_decline(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches;
begin
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'pending' then raise exception 'That challenge is gone'; end if;
  if not m.friendly then update profiles set balance = balance + m.stake where id = m.a; end if;
  update pvp_matches set status = case when m.a = me then 'cancelled' else 'declined' end where id = m.id;
  return json_build_object('ok', true, 'balance', (select balance from profiles where id = me));
end $$;

create or replace function pvp_move(p_id uuid, p_hit boolean) returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m pvp_matches; is_a boolean; c int[];
begin
  select * into m from pvp_matches where id = p_id and (a = me or b = me) for update;
  if not found or m.status <> 'live' then raise exception 'No match in play'; end if;
  is_a := m.a = me;
  if (is_a and m.a_done) or (not is_a and m.b_done) then raise exception 'You''re done this hand. Waiting on your opponent.'; end if;
  if is_a then
    c := case when p_hit then m.a_cards || m.deck[1] else m.a_cards end;
    update pvp_matches set a_cards = c, deck = case when p_hit then deck[2:] else deck end,
           a_done = not p_hit or _bj_total(c) >= 21, a_acted = now() where id = m.id;
  else
    c := case when p_hit then m.b_cards || m.deck[1] else m.b_cards end;
    update pvp_matches set b_cards = c, deck = case when p_hit then deck[2:] else deck end,
           b_done = not p_hit or _bj_total(c) >= 21, b_acted = now() where id = m.id;
  end if;
  perform _pvp_settle(m.id);
  select * into m from pvp_matches where id = p_id;
  return _pvp_view(m, me);
end $$;

-- everything the 1v1 tab needs: incoming / outgoing challenges and my current match
create or replace function pvp_state() returns json
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cur pvp_matches;
begin
  if me is null then return null; end if;
  perform _pvp_tidy();
  select * into cur from pvp_matches where (a = me or b = me) and status in ('live', 'done')
   order by created_at desc limit 1;
  return json_build_object(
    'incoming', (select coalesce(json_agg(json_build_object('id', m.id, 'from', p.username, 'stake', m.stake, 'friendly', m.friendly) order by m.created_at), '[]')
                   from pvp_matches m join profiles p on p.id = m.a where m.b = me and m.status = 'pending'),
    'outgoing', (select json_build_object('id', m.id, 'to', p.username, 'stake', m.stake, 'friendly', m.friendly)
                   from pvp_matches m join profiles p on p.id = m.b where m.a = me and m.status = 'pending' limit 1),
    'match', case when cur.id is null then null else _pvp_view(cur, me) end);
end $$;

-- refill is also blocked while you have a 1v1 going
create or replace function claim_refill() returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from crash_rounds where user_id = auth.uid() and status = 'live'
               and extract(epoch from clock_timestamp() - started_at) < ln(crash_point) / 0.09)
     or exists (select 1 from ride_rounds where user_id = auth.uid() and status = 'live')
     or exists (select 1 from bj_hands where user_id = auth.uid() and status = 'live')
     or exists (select 1 from pvp_matches where (a = auth.uid() or b = auth.uid()) and status in ('pending', 'live')) then
    raise exception 'Finish your current game before refilling';
  end if;
  update profiles set balance = 100 where id = auth.uid() and balance < 10 returning balance into bal;
  if bal is null then raise exception 'Refill only works under 10 coins'; end if;
  return json_build_object('balance', bal);
end $$;

notify pgrst, 'reload schema';
