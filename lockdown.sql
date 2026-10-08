-- Jambling: lockdown. Run once in Supabase > SQL Editor.
-- Pauses every way coins can move between players (gifts + money 1v1s).
-- Friendly 1v1s and all solo games keep working.

create or replace function gift_coins(p_to text, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Gifting is turned off';
end $$;

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
  if not p_friendly then raise exception 'Money 1v1s are paused for now. Friendly still works.'; end if;
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

-- refund any money challenges still waiting to be accepted
with c as (
  update pvp_matches set status = 'cancelled' where status = 'pending' and not friendly returning a, stake
)
update profiles p set balance = balance + c.stake from c where p.id = c.a;

notify pgrst, 'reload schema';
