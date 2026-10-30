-- Jambling: Murphy's Law becomes "Abuser", given by admins (no longer earned from coin flips). Run once in Supabase > SQL Editor.
-- the murphy flag is reused for the Abuser title; everyone who had Murphy's Law loses it
update profiles set murphy = false where murphy;
update profiles set granted_titles = array_replace(granted_titles, 'Murphy''s Law', 'Abuser') where 'Murphy''s Law' = any(granted_titles);
update profiles set hidden_titles = array_replace(hidden_titles, 'Murphy''s Law', 'Abuser') where 'Murphy''s Law' = any(hidden_titles);

create or replace function admin_grant_abuser(p_user text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select id, username into them, them_name from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  update profiles set murphy = p_on where id = them;
  if _is_staff_not_owner() then perform _log_staff(them_name, case when p_on then 'granted the Abuser title' else 'removed the Abuser title' end); end if;
  return json_build_object('user', them_name, 'abuser', p_on);
end $$;
revoke execute on function admin_grant_abuser(text, boolean) from anon;
grant execute on function admin_grant_abuser(text, boolean) to authenticated;

-- coin flip no longer hands out the title
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
  return json_build_object('result', res, 'won', won, 'balance', bal, 'delta', delta);
end $$;

-- the "any title" list for max: Murphy's Law -> Abuser
create or replace function owner_grant_title(p_user text, p_title text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare them uuid; them_name text; has_tester boolean; g text[];
begin
  if not am_owner() then raise exception 'Only max can grant titles'; end if;
  if p_title not in ('Creator', 'OG', 'Aurora', 'Tester', 'Jew', 'Quick', 'Abuser', 'Spoiled', 'Goated', 'Untouchable', 'Touchable',
                     'Reborn', 'Ascended', 'The Golden', 'Celestial', 'GGEZ', 'King', 'Elite') then
    raise exception 'Unknown title %', p_title;
  end if;
  select id, username, tester into them, them_name, has_tester from profiles where lower(username) = lower(trim(p_user)) order by created_at limit 1;
  if them is null then raise exception 'No player named %', p_user; end if;
  if p_on and p_title = 'Creator' and not coalesce(has_tester, false) then raise exception '% needs the Tester title first', them_name; end if;
  if p_title = 'Tester' then update profiles set tester = p_on where id = them;
  elsif p_title = 'Aurora' then update profiles set gifted = p_on where id = them;
  elsif p_title = 'OG' then update profiles set og = p_on where id = them;
  elsif p_title = 'Jew' then update profiles set jew = p_on where id = them;
  elsif p_title = 'Quick' then update profiles set speedrun = p_on where id = them;
  elsif p_title = 'Abuser' then update profiles set murphy = p_on where id = them;
  elsif p_on then update profiles set granted_titles = array_append(array_remove(granted_titles, p_title), p_title) where id = them;
  else update profiles set granted_titles = array_remove(granted_titles, p_title) where id = them; end if;
  select granted_titles into g from profiles where id = them;
  perform _log_staff(them_name, case when p_on then 'granted the ' || p_title || ' title' else 'removed the ' || p_title || ' title' end);
  return json_build_object('user', them_name, 'title', p_title, 'on', p_on, 'granted', g);
end $$;

notify pgrst, 'reload schema';
