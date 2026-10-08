-- Jambling: find the thief. Run each block on its own (highlight it, then Run).

-- A) one device logging into lots of accounts = the thief (last 3 days)
select ip_address, count(distinct payload->>'actor_id') as accounts, count(*) as logins, max(created_at) as last_seen
from auth.audit_log_entries
where payload->>'action' = 'login' and created_at > now() - interval '3 days'
group by ip_address order by accounts desc limit 10;

-- B) money 1v1s in the last 3 days: who lost coins to who
select m.created_at, pa.username as challenger, pb.username as opponent, m.stake,
       pw.username as winner, m.result
from pvp_matches m
join profiles pa on pa.id = m.a join profiles pb on pb.id = m.b
left join profiles pw on pw.id = m.winner
where not m.friendly and m.status = 'done' and m.created_at > now() - interval '3 days'
order by m.created_at desc;

-- C) gifts in the last 3 days (should be empty if gifting is really off)
select g.created_at, f.username as from_user, t.username as to_user, g.amount
from gifts g join profiles f on f.id = g.from_id join profiles t on t.id = g.to_id
where g.created_at > now() - interval '3 days' order by g.created_at desc;
