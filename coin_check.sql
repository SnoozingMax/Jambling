-- Jambling: why does Coin Flip keep losing? Run in Supabase > SQL Editor and send me the results.
-- 1) anything forcing losses on your account (bad luck, rigged) and the big-bet rule
select username, badluck_until, badluck_until > now() as bad_luck_active, rigged, boost_until, rebirths
from profiles where lower(username) = 'max';

-- 2) your last 30 flips: how many won, and how big the bets were
select count(*) as flips, count(*) filter (where won) as wins,
       count(*) filter (where bet > 10000000) as big_bets_over_10m
from (select * from coin_flips where user_id = (select id from profiles where lower(username) = 'max' order by created_at limit 1)
      order by created_at desc limit 30) t;

-- 3) every flip_coin version in the database (there should be exactly one)
select oid::regprocedure from pg_proc where proname = 'flip_coin';
