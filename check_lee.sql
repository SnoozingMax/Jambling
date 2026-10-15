-- Jambling: what happened to "lee". Run in Supabase > SQL Editor. Newest first.
with p as (select * from profiles where lower(username) = 'lee'),
u as (select id, created_at, last_sign_in_at from auth.users where lower(email) = 'lee@users.jambling.app')
select at, what from (
  -- account status right now
  select now() as at,
    case when not exists (select 1 from u) and not exists (select 1 from p) then 'NO ACCOUNT: lee does not exist (deleted, or never made)'
         when not exists (select 1 from p) then 'LOGIN EXISTS BUT PROFILE DELETED'
         else 'NOW: balance ' || to_char((select balance from p), 'FM999,999,999,990.00')
              || ' | banned ' || (select banned from p) || ' | approved ' || (select approved from p)
              || ' | rejected ' || ((select rejected_at from p) is not null) || ' | leaderboard banned ' || coalesce((select board_hidden from p), false)
              || ' | rebirths ' || (select rebirths from p)
              || ' | bad luck ' || coalesce((select badluck_until > now() from p), false) end as what
  union all select (select created_at from u), 'Account created'
  union all select (select last_sign_in_at from u), 'Last sign-in'
  union all select (select last_seen from p), 'Last seen on site'
  -- staff actions on lee (admins/mods)
  union all select at, 'STAFF: ' || coalesce(actor_name, '?') || ' -> ' || what from staff_log where lower(target_name) = 'lee'
  union all select b.at, 'BAD LUCK given by ' || coalesce(x.username, '?') from badluck_log b left join profiles x on x.id = b.by_user where b.target in (select id from p)
  union all select m.at, 'MOD GRANT +' || m.amount || ' from ' || coalesce(x.username, '?') from mod_grants m left join profiles x on x.id = m.by_user where m.target in (select id from p)
  -- gifts in and out
  union all select g.created_at, 'GIFT ' || g.status || ': lee -> ' || coalesce(x.username, '?') || ' ' || g.amount from gifts g left join profiles x on x.id = g.to_id where g.from_id in (select id from p)
  union all select g.created_at, 'GIFT ' || g.status || ': ' || coalesce(x.username, '?') || ' -> lee ' || g.amount from gifts g left join profiles x on x.id = g.from_id where g.to_id in (select id from p)
  -- big game results (bet 1,000+)
  union all select started_at, 'RIDE bet ' || bet || ' paid ' || coalesce(payout, 0) from ride_rounds where user_id in (select id from p) and bet >= 1000
  union all select started_at, 'ROCKET bet ' || bet || ' ' || status || ' at ' || coalesce(cashout::text, crash_point::text) from crash_rounds where user_id in (select id from p) and bet >= 1000
  union all select created_at, 'BLACKJACK bet ' || bet || ' ' || coalesce(result, status) || ' paid ' || payout from bj_hands where user_id in (select id from p) and bet >= 1000
  union all select created_at, 'MINES bet ' || bet || ' ' || status || ' paid ' || payout from mines_rounds where user_id in (select id from p) and bet >= 1000
  union all select created_at, 'ROULETTE bet ' || bet || ' on ' || kind || ' paid ' || payout from roulette_spins where user_id in (select id from p) and bet >= 1000
  union all select m.created_at, '1V1 vs ' || coalesce(x.username, '?') || ' stake ' || m.stake || ' ' || coalesce(m.result, m.status) from pvp_matches m left join profiles x on x.id = case when m.a in (select id from p) then m.b else m.a end where (m.a in (select id from p) or m.b in (select id from p)) and not m.friendly
) t
where at is not null
order by at desc
limit 200;
