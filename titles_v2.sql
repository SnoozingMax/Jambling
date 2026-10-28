-- Jambling: GGEZ + Murphy's Law titles, and a title inventory (hide/show the titles you have). Run once in Supabase > SQL Editor.
alter table profiles add column if not exists ggez boolean not null default false;        -- won 3 1v1s in a row
alter table profiles add column if not exists murphy boolean not null default false;      -- lost a 1b+ coin flip
alter table profiles add column if not exists pvp_streak int not null default 0;          -- current 1v1 win streak
alter table profiles add column if not exists hidden_titles text[] not null default '{}'; -- titles this player chose not to show

-- 1v1 results now track win streaks: 3 wins in a row (any 1v1 game, including Archers) unlocks GGEZ
create or replace function _pvp_finish(p_id uuid, w uuid, res text) returns void
language plpgsql security definer set search_path = public as $$
declare m pvp_matches; s int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'live' then return; end if;
  if not m.friendly then
    if w is null then update profiles set balance = balance + m.stake where id in (m.a, m.b);
    else update profiles set balance = balance + m.stake * 2 where id = w; end if;
  end if;
  update pvp_matches set status = 'done', winner = w, result = res where id = m.id;
  if w is null then update profiles set pvp_streak = 0 where id in (m.a, m.b);
  else
    update profiles set pvp_streak = pvp_streak + 1 where id = w returning pvp_streak into s;
    update profiles set pvp_streak = 0 where id = case when w = m.a then m.b else m.a end;
    if s >= 3 then update profiles set ggez = true where id = w; end if;
  end if;
end $$;

-- coin flip: losing a bet of 1 billion or more unlocks Murphy's Law
create or replace function flip_coin(p_bet numeric, p_pick text) returns json
language plpgsql security definer set search_path = public as $$
declare
  bal numeric;
  res text;
  won boolean;
  delta numeric;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  p_bet := round(p_bet, 2);
  if p_bet is null or p_bet <= 0 then raise exception 'Invalid bet'; end if;
  if p_pick not in ('heads', 'tails') then raise exception 'Invalid pick'; end if;

  select balance into bal from profiles where id = auth.uid() for update;
  if bal < p_bet then raise exception 'Not enough coins'; end if;

  if _bad_luck_now(auth.uid()) then res := case when p_pick = 'heads' then 'tails' else 'heads' end;   -- always lose
  elsif (select boost_until > clock_timestamp() from profiles where id = auth.uid()) then res := p_pick;   -- good luck: always win
  elsif p_bet > 10000000 then res := case when random() < 0.40 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- big bets: 40% win
  elsif _rush_now() then res := case when random() < 0.90 then p_pick when p_pick = 'heads' then 'tails' else 'heads' end;   -- rush hour: 90% win
  else res := case when random() < (case when _rigged(auth.uid()) then 0.44 else 0.5 end) then p_pick when p_pick = 'heads' then 'tails' else 'heads' end; end if;   -- rigged players: 44% win
  won := res = p_pick;
  delta := case when won then round(p_bet * _luck(auth.uid()), 2) else -p_bet end;   -- no max win on Coin Flip

  update profiles set balance = balance + delta where id = auth.uid() returning balance into bal;
  insert into coin_flips (user_id, bet, pick, result, won, delta) values (auth.uid(), p_bet, p_pick, res, won, delta);
  if not won and p_bet >= 1000000000 then update profiles set murphy = true where id = auth.uid(); end if;
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta, 'murphy', (not won and p_bet >= 1000000000));
end $$;

-- title inventory: hide or show one of your titles
create or replace function set_title_hidden(p_title text, p_hidden boolean) returns text[]
language plpgsql security definer set search_path = public as $$
declare h text[];
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_hidden then update profiles set hidden_titles = array_append(array_remove(hidden_titles, p_title), p_title) where id = auth.uid() returning hidden_titles into h;
  else update profiles set hidden_titles = array_remove(hidden_titles, p_title) where id = auth.uid() returning hidden_titles into h; end if;
  return h;
end $$;
revoke execute on function set_title_hidden(text, boolean) from anon;
grant execute on function set_title_hidden(text, boolean) to authenticated;

notify pgrst, 'reload schema';
